## 1.MapReduce中排序发生在哪几个阶段？

一个MapReduce作业由Map阶段和Reduce阶段两部分组成，这两阶段会对数据排序，从这个意义上说，MapReduce框架本质就是一个Distributed Sort。

在Map阶段，Map Task会在本地磁盘输出一个按照key排序（采用的是快速排序）的文件（中间可能产生多个文件，但最终会合并成一个）。Map端sort是用来shuffle的，shuffle就是把相同的key弄一起去，其实不一定要sort也能shuffle，但是sort的好处是他可以通过外排降低内存使用量。

在Reduce阶段，每个Reduce Task会对收到的数据排序，这样，数据便按照Key分成了若干组，之后以组为单位交给reduce（）处理。

很多人的误解在Map阶段，如果不使用Combiner便不会排序，这是错误的，不管你用不用Combiner，Map Task均会对产生的数据排序（如果没有Reduce Task，则不会排序， 实际上Map阶段的排序就是为了减轻Reduce端排序负载）。

排序是MapReduce框架最重要的操作之一，任何应用程序中的MapTask和ReduceTask均会对数据按照key进行排序。该操作属于Hadoop的默认行为。任何应用程序中的数据均会被排序，而不管逻辑上是否需要。

默认排序是按照字典顺序排序，且实现该排序的方法是快速排序。

## 2.排序概述

对于MapTask，它会将处理的结果暂时放到环形缓冲区中，当环形缓冲区使用率达到一定阈值（80%）后，再对缓冲区中的数据进行一次快速排序，并将这些有序数据溢写到磁盘上，而当数据处理完毕后，它会对磁盘上所有文件进行归并排序。

对于ReduceTask，它从每个MapTask上远程拷贝相应的数据文件，如果文件大小超过一定阈值，则溢写磁盘上，否则存储在内存中。如果磁盘上文件数目达到一定阈值，则进行一次归并排序以生成一个更大文件；如果内存中文件大小或者数目超过一定阈值，则进行一次合并后将数据溢写到磁盘上。当所有数据拷贝完毕后，ReduceTask统一对内存和磁盘上的所有数据进行一次归并排序。

## 3.为什么要进行排序操作呢？

简而言之，减轻Reduce端排序负载。


## 4.排序分类

### 4.1 部分排序

MapReduce根据输入记录的键对数据集排序。**保证输出的每个文件内部有序**。

### 4.2 全排序

MapReduce默认只是保证同一个分区内的Key是有序的，但是不保证全局有序。如果我们将所有的数据全部发送到一个Reduce，那么就可以实现结果全局有序。

但该方法在处理大型文件时效率极低，因为一台机器处理所有文件，完全丧失了MapReduce所提供的并行架构。而且在数据量很大的情况下，很有可能会出现OOM问题。

在hadoop分区的介绍中，我们知道MapReduce默认的分区函数是HashPartitioner，其实现的原理是计算map输出key的hashCode，然后对Reduce个数求模，这样只要求模结果一样的Key都会发送到同一个Reduce。所以，可以通过自定义分区函数的方式实现全局排序。

主要思路是使用一个分区来描述输出的全局排序。例如：可以为待分析文件创建3个分区，在第一分区中，记录的单词首字母a-g，第二分区记录单词首字母h-n, 第三分区记录单词首字母o-z。

这就实现了Reduce 0的数据一定全部小于Reduce 1，且Reduce 1的数据全部小于Reduce 2，再加上同一个Reduce里面的数据局部有序，这样就实现了数据的全局有序。

二次排序代码实现如下所示：
```java
public static class SecondPartitioner extends Partitioner<Text, IntWritable> {
    @Override
    public int getPartition(Text key, IntWritable value, int numPartitions) {
        char[] chs = key.toString().toCharArray();
        // 首字母a-g，第二分区记录单词首字母h-n, 第三分区记录单词首字母o-z。
        if (chs[0] >= 'a' && chs[0] <= 'g' ) {
            return 0;
        } else if (chs[0] >= 'h' && chs[0] <= 'n') {
            return 1;
        } else {
            return 2;
        }
    }
}
```

将reduce的任务个数设置为3：
```java
job.setNumReduceTasks(3);
```
程序生成了三个文件（因为我们设置了Reduce个数为3），而且每个文件都是局部有序；所有首字母是a-g的数据都在part-r-00000里面，所有单词首字母是h-n的数据都在part-r-00001里面，所有单词首字母是o-z的数据都在part-r-00002里面。part-r-00000、part-r-00001和part-r-00002三个文件实现了全局有序。

### 4.3 辅助排序（GroupingComparator分组）

在reduce端对key进行分组，应用于：在接受的key为bean对象时，想让一个或者几个字段相同（全部字段比较不相同）的key进入到同一个reduce方法时，可以采用分组排序。


### 4.4 二次排序

在自定义排序的过程中，如果compareTo中的条件为两个，就是二次排序。

## 如何在Reduce阶段对value进行排序？ 

编写MapReduce作业时，如何做到在Reduce阶段，先对Key排序，再对Value排序？？

答：该问题通常称为“二次排序”，最常用的方法是将Value放到Key中，实现一个组合Key，然后自定义Key排序规则（为Key实现一个WritableComparable）


我们知道，MapReduce 程序中，Mapper 输出的键值对会经历 shuffle 过程再交给 Reducer。在 shuffle 阶段，Mapper 输出的键值对会经过 partition(分区)->sort(排序)->group(分组) 三个阶段。

既然 MapReduce 框架自带排序，那么二次排序中的排序是否可以交给 shuffle 中的 sort 来执行呢？
答案是肯定的，而且 shuffle 的 sort 在大量数据的情况下具有很高的效率。

shuffle 的 sort 过程会根据键值对<key, value>的 key 进行排序，但是二次排序中，value 也是需要排序的字段。因此需要将 value 字段合并到 key 中作为新的 key，形成新的键值对<key#value, value>。在排序时使其先根据 key 排序，如果相同，再根据 value 排序。

下图详细描述了二次排序的流程，虚线框内为 shuffle 过程：

![image](https://user-images.githubusercontent.com/30204737/120892535-6a170700-c641-11eb-8963-316caf8aefc6.png)

可以发现，在 Map 阶段，程序将原本的 key 和 value 组合成一个新的 key，这是一个新的数据类型。因此需要在程序中定义该数据类型，为了使它支持排序，还需定义它的比较方式。根据二次排序的规则，比较方式为：先比较第一个字段，如果相同再比较第二个字段。

Map 操作结束后，数据的 key 已经改变，但是分区依旧要按照原本的 key 进行，否则原 key 不同的数据会被分到一起。举个例子，<1#1, 1>、<1#3, 3>、<1#5, 5>应该属于同一个分区，因为它们的原 key 都是1。如果按照新 key 进行分区，那么可能<1#1, 1>、<1#3, 3>在同一个分区，<1#5, 5>被分到另一个分区。

分区和排序结束后进行分组，很显然分组也是按照原 key 进行。

我们需要自定义序列化类型PairWritable，将key和vale组合为新的key。下面贴出核心的compareTo比较代码：
```java
public int compareTo(PairWritable o) {
    // 先比较 first
    int compare = Integer.valueOf(this.getFirst()).compareTo(o.getFirst());
    if (compare != 0) {
        return compare;
    }
    // first 相同再比较 second
    return Integer.valueOf(this.getSecond()).compareTo(o.getSecond());
}
```

参考链接：

[Hadoop：二次排序实现](https://www.jianshu.com/p/bab62802d109)

[三种方法实现Hadoop(MapReduce)全局排序](https://cloud.tencent.com/developer/article/1199755)
