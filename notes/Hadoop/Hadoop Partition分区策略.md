## 1.如何为数据指定分区？

在处理需求的时候，需要将结果按照不同的条件输出到不同的文件中（分区）。例如，将江苏省和北京市的人输出到同一个文件中（同一个分区）。

在Hadoop中，默认的分区策略是HashPartitioner。

分区发生在map写出之后，我们通过debug的方式，查看具体的分区流程。

## 2.不指定Reduce个数

```java
// 2.
@Override
public void write(KEYOUT key, VALUEOUT value) throws IOException,
    InterruptedException {
  mapContext.write(key, value);
}

// 3.
/**
 * Generate an output key/value pair.
 */
public void write(KEYOUT key, VALUEOUT value
                  ) throws IOException, InterruptedException {
  output.write(key, value);
}

// 
@Override
public void write(K key, V value) throws IOException, InterruptedException {
  collector.collect(key, value,
                    partitioner.getPartition(key, value, partitions));
}

// 分区器将返回分区0，默认分区数是1
partitioner = new org.apache.hadoop.mapreduce.Partitioner<K,V>() {
  @Override
  public int getPartition(K key, V value, int numPartitions) {
    return partitions - 1;
  }
};
```


## 3.指定Reduce个数
```java
job.setNumReduceTasks(2);
```

我们再看一下分区流程：

```java
// 上面的流程不变，在获取分区的时候代码发生了变化
/** Use {@link Object#hashCode()} to partition. */
public int getPartition(K key, V value,
                        int numReduceTasks) {
  return (key.hashCode() & Integer.MAX_VALUE) % numReduceTasks;
}
```
默认分区是根据key的hashCode对reduce个数取模得到，用户没有办法为数据指定分区。如果我们想为数据指定分区，那么只能自定义分区器。

## 4.分区器选择逻辑

完整的分区计算逻辑如下：

```java
NewOutputCollector(org.apache.hadoop.mapreduce.JobContext jobContext,
                   JobConf job,
                   TaskUmbilicalProtocol umbilical,
                   TaskReporter reporter
                   ) throws IOException, ClassNotFoundException {
  collector = createSortingCollector(job, reporter);
  partitions = jobContext.getNumReduceTasks();
  // 如果分区数大于1个，就使用默认的HashPartitioner
  if (partitions > 1) {
    partitioner = (org.apache.hadoop.mapreduce.Partitioner<K,V>)
      ReflectionUtils.newInstance(jobContext.getPartitionerClass(), job);
  } else {
    // 如果分区数是一个，则直接返回分区0，最终只会产生0号分区的文件
    partitioner = new org.apache.hadoop.mapreduce.Partitioner<K,V>() {
      @Override
      public int getPartition(K key, V value, int numPartitions) {
        return partitions - 1;
      }
    };
  }
}

```
## 5.自定义分区


```java
public class MyPartitioner extends Partitioner<Text, IntWritable> {
    /**
     * 将key包含江苏省和北京市的数据放入0号分区，其他数据放入1号分区
     */
    @Override
    public int getPartition(Text text, IntWritable intWritable, int numPartitions) {
        // 控制分区逻辑
        if(Pattern.matches("江苏省|北京市", text.toString())){
            return 0;
        }
        return 1;
    }
}
```

为了让我们的程序使用自定义的分区，我们需要在Job中指定分区器信息。
```java
job.setPartitionerClass(MyPartitioner.class);
```

最后，我们还需要执行reduce个数，否则程序会直接使用默认的0号分区，而不会进入到指定分区器的代码流程中。
```java
job.setNumReduceTasks(2);
```

## 6.分区数与reduce个数使用总结

* 如果reduce的个数 > partition分区的个数，则会产生空的part-r-000xx文件；
* 如果1 < reduce的个数 < partition分区的个数，则有一部分数据无法安放，会抛出异常；
* 如果 reduce的个数 = 1，会直接放回分区0，最终结果都交给一个ReduceTask，最终也只会产生一个结果文件part-r-00000；
* 分区号必须从0开始累加；
