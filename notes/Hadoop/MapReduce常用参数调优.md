## 1.影响MapReduce性能的原因

（1）计算机性能

CPU、内存、磁盘、网络。

（2）I/O操作性能

* 数据倾斜 
* Map 运行时间太长，导致 Reduce 等待过久 
* 小文件过多

## 2.Map任务参数优化

* 自定义分区，减少数据倾斜

* 减少溢写次数

```java
// shuffle的环形缓冲区大小，默认是100M，可以提高到200M
mapreduce.task.io.sort.mb
// 环形缓冲区溢写的阈值是80%，可以提高到90%
mapreduce.map.sort.spill.percent
```

* 增加每次merge合并次数

```java
// 默认是10个文件，可以提高到20个
mapreduce.task.io.sort.factor
```

* 在不影响业务结果的情况下，使用Combiner

```java
job.setCombinerClass(Reducer.class)
```

* 为了减少磁盘IO，可以采用Snppy或者LZO压缩算法

```java
conf.setBoolean("mapreduce.map.output.compress", true);
conf.setClass("mapreduce.map.output.compress.codec", SnappyCodec.class, CompressionCodec.class);
```

* 设置MapTask内存上线

```java
// 默认是1024MB,对于128G的数据来说，配置1G的内存可以
mapreduce.map.memory.mb
// 如果内存不够用，会报OOM异常
mapreduce.map.java.opts
// 上述两个参数一起使用，只设置其中一个不起作用
```

* 设置MapTask的CPU核数

```java
// 对于计算密集型任务，可以增加CPU核数
mapreduce.map.cpu.vcores=1	
```



## 3.Reduce任务参数优化

* 设置每个reduce任务去map中拉取数据的并行数

```java
// 默认是5，可以设置为10
mapreduce.reduce.shuffle.parallelcopies=5
```

* 设置buffer大小占Reduce可用内存的比例，默认0.7

```java
mapreduce.reduce.shuffle.input.buffer.percent
```

* 设置ReduceTask内存上限

```java
// 根据128M数据对应1G内存，可以适当提高到4~6G  
mapreduce.reduce.memory.mb  // 默认是1G
// 控制ReducTask堆内存的大小
mapreduce.reduce.java.opts
```

* 设置ReduceTask的CPU核数

```java
// 对于计算密集型任务，可以增加CPU核数
mapreduce.reduce.cpu.vcores=1	// 可以适当提高到2~4个
```

