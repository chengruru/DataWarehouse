

## 1.为什么要Combiner？


我们以经典的词频统计WordCount，看一下MapReduce计算过程，如下图所示。

<div align="center"> <img src="https://user-images.githubusercontent.com/30204737/120893179-76e92a00-c644-11eb-8306-6d3f5e7c90ab.png" > </div><br>

Hadoop框架使用Mapper将数据处理成一个个的<key,value>键值对，在网络节点间对其进行整理(shuffle)，然后使用Reducer处理数据并进行最终输出。

从上述wordcount计算过程中，我们不难发现存在两个性能瓶颈：

* 网络带宽严重被占降低程序效率

如果我们有10亿个数据，Mapper会生成10亿个键值对在网络间进行传输，但如果我们只是对数据求最大值，那么很明显的Mapper只需要输出它所知道的最大值即可。这样做不仅可以减轻网络压力，同样也可以大幅度提高程序效率。


* 单一节点承载过重降低程序性能

数据远远不是一致性的或者说平衡分布的，在词频统计例子中，日常我们常用词“我”，“的”，“地”等词的使用频率远远高于其他词。这必然会导致某个Reduce聚集过多的数据，从而压倒这个Reducer，从而大大降低程序的性能。

Combiner在某些情况下，可以很好的解决这两个问题。

## 2.Combiner概述

Combiner的核心思想是：对map本地数据进行预聚合。使用Combiner之后传输到reduce的数据量有所减少才是Combiner存在的意义，在部分情况下使用Combiner会使程序性能提升N倍。

如果在wordcount中不用combiner，那么所有的结果都是reduce完成，效率会相对低下。使用combiner之后，先完成的map会在本地聚合，提升速度。对于hadoop自带的wordcount的例子，value就是一个叠加的数字，所以map一结束就可以进行reduce的value叠加，而不必要等到所有的map结束再去进行reduce的value叠加。

融合Combiner的MapReduce过程如下图所示：


<div align="center"> <img src="https://user-images.githubusercontent.com/30204737/120893408-c8de7f80-c645-11eb-977d-68075deb13ca.png" > </div><br>

Combiner是一个“迷你reduce”过程，它只处理单台机器生成的数据。

使用Combiner前后数据量对比：

（1）未使用Combiner的传输数据量

<div align="center"> <img src="https://user-images.githubusercontent.com/30204737/120893613-c9c3e100-c646-11eb-9b98-4b10a039a9b4.png" > </div><br>

（2）使用Combiner的传输数据量

<div align="center"> <img src="https://user-images.githubusercontent.com/30204737/120894585-c2eb9d00-c64b-11eb-9c9a-90ac91211654.png" > </div><br>


可以看出，使用Combiner之后，能够节省很大的带宽。

## 3.Combiner的执行位置

Combiner调用的位置有两处：

* 发生在MapTask发生溢写的时候，将同一个key的<key, value>进行合并。
* 对map任务产生的多个溢写文件进行归并排序的时候。

<div align="center"> <img src="https://user-images.githubusercontent.com/30204737/120894234-05ac7580-c64a-11eb-8ff6-ba9c803c1c6c.png" > </div><br>

WordCount程序使用Combiner的数据流图：

<div align="center"> <img src="https://user-images.githubusercontent.com/30204737/120894065-26280000-c649-11eb-8a78-c3332d0e8bef.png" > </div><br>

## 4.Combiner实现

```java
public class MyCombiner extends Reducer<Text, IntWritable, Text, IntWritable> {
    private IntWritable result = new IntWritable(); 
    /**
     * Combiner的作用：主要为了合并数据，执行在map
     * -partitioner之后，reduce之前。使用之后传输到reduce的数据量有所减少才是Combiner存在的意义
     * 
     */
    public void reduce(Text key, Iterable<IntWritable> values, Context context)
            throws IOException, InterruptedException {
        int sum = 0;
        // 数据相加取和
        for (IntWritable val : values) {
            sum += val.get();
        }
        result.set(sum);
        context.write(key, result);
    }
}
```

Combiner继承Reducer类，其实现逻辑和Reducer是一样的，在实际的使用中，通常可以直接将Combiner设置为Reducer的实现类。

在job中，we设置Combiner类:

```java
job.setCombinerClass(MyCombiner.class); // 为job设置Combiner类
```

通过查看程序执行日志，可以看出传输到Reduce端的数据明显变小：

（1）未使用Combiner的WordCount程序日志输出

<div align="center"> <img src="https://user-images.githubusercontent.com/30204737/120894489-393bcf80-c64b-11eb-8326-20b44c2f1f49.png" > </div><br>

（2）使用Combiner的WordCount程序日志输出

<div align="center"> <img src="https://user-images.githubusercontent.com/30204737/120894538-80c25b80-c64b-11eb-8b22-e9fe57d2c467.png" > </div><br>

## 5.Combiner使用注意事项

* 与mapper和reducer不同的是，combiner没有默认的实现，需要显式的设置在conf中才有作用。
* 并不是所有的job都适用combiner，只有操作满足结合律的才可设置combiner。如果为求和、求最大值的话，可以使用，但是如果是求中值的话，不适用。
* Combiner在map与reduce之间，针对每个key，有可能会被平用若干次。
* combiner的意义就在于对每个MapTask的输出进行局部汇总，以减少网络传输量。
* 特别值得注意的一点，一个combiner只是处理一个结点中的的输出，而不能享受像reduce一样的输入（经过了shuffle阶段的全量数据）。

每一个map都可能会产生大量的本地输出 ，Combiner的作用就是对map端的输出先做一次合并，以减少在map和reduce节点之间的数据传输量，以提高网络IO性能，是MapReduce的一种优化手段之一。

参考链接：

[Hadoop学习笔记—8.Combiner与自定义Combiner](https://www.cnblogs.com/edisonchou/p/4297786.html)

[MapReduce中Combiner的作用](https://blog.csdn.net/zpf336/article/details/82181304)
