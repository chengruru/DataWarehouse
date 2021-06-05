MapReduce的数据流：
![image](https://user-images.githubusercontent.com/30204737/120886938-f6fe9800-c622-11eb-9275-238fa36f8fe7.png)

map阶段我们称之为MapTask，reduce阶段我们则称之为ReduceTask。默认读取输入文件是按行读取。key是偏移量，value则是行内容。InputFormat可以对输入进行控制，有非常多的类可以实现不同的数据读取方式。数据读取之后，就回交给Mapper类进行后续的业务逻辑处理。

## 1.切片与MapTask并行度决定机制
（1）问题引出：MapTask并行度怎么确定？

MapTask 的并行度决定 Map 阶段的任务处理并发度，进而影响到整个 Job 的处理速度。

思考：1G 的数据，启动 8 个 MapTask，可以提高集群的并发处理能力。

那么 1K 的数据，也启动 8 个 MapTask，会提高集群性能吗？MapTask 并行任务是否越多越好呢？哪些因素影响了 MapTask 并行度？

（2）MapTask并行度决定机制

<font color='red'>数据块：</font>Block是HDFS物理上把数据分成一块一块。

<font color='red'>数据切片：</font>数据切片知识在逻辑上对输入进行分片，并不会在磁盘上将其切分成片进行存储。数据切片是 MapReduce 程序计算输入数据的单位，一个切片会对应启动一个 MapTask。


## 2.切片大小对于数据处理的影响

**假设切片大小设置为100M**

![image](https://user-images.githubusercontent.com/30204737/120887048-65435a80-c623-11eb-9b9c-5ab59d7c81c7.png)

DataNode1节点上的128M数据，会切分成100M和28M，其中100M的数据交给本地的MapTask进行处理。剩余的28M数据，则会通过网络传输到DataNode2节点的MapTask进行处理。

同理，我们可以知道如果切片的大小大于块的大小，同样也需要将数据从其他数据节点拷贝到MapTask所在的机器上。

<font color='red'>**这种切片切分方式需要网络传输，会很慢。**</font>

那么，切片的个数就决定了我们开启MapTask的个数。文件切片是在什么时候确定的？


1）一个Job的Map阶段并行度由客户端在提交Job时的切片数决定；

2）每一个split切片分配一个MapTask并行实例处理；

3）默认情况下，切片大小=BlockSize；

4）切片时不考虑数据集整体，而是逐个针对每一个文件单独切片。

下面我们通过文件切片源码看一下，具体的工作流程。

## 3.任务提交源码解读

```java
public void submit() 
         throws IOException, InterruptedException, ClassNotFoundException {
    // 再次确保state是DEFINE状态
    ensureState(JobState.DEFINE);
    // 兼容新旧版本的hadoop代码，使用新的api
    setUseNewAPI();
    // 连接集群，yarn
    // 若是本地集群返回localCluster,yarn集群则返回yarnCluster
    connect();
    final JobSubmitter submitter = 
        getJobSubmitter(cluster.getFileSystem(), cluster.getClient());
    status = ugi.doAs(new PrivilegedExceptionAction<JobStatus>() {
      public JobStatus run() throws IOException, InterruptedException, 
      ClassNotFoundException {
        // 此处是job提交前的工作
        // 1.Jar包
        // 2.xml文件
        // 3.切片信息
        return submitter.submitJobInternal(Job.this, cluster);
      }
    });
    state = JobState.RUNNING;
    LOG.info("The url to track the job: " + getTrackingURL());
}
```

## 4.切片切分逻辑

切片的实际切分信息是在客户端向集群提交信息之前完成的，也就是上述代码中的这条语句：

```java
// 此处是job提交前的工作
// 1.Jar包
// 2.xml文件
// 3.切片信息
return submitter.submitJobInternal(Job.this, cluster);
```
submitJobInternal方法：

```java
JobStatus submitJobInternal(Job job, Cluster cluster) 
throws ClassNotFoundException, InterruptedException, IOException {

  //validate the jobs output specs 
  checkSpecs(job);

  Configuration conf = job.getConfiguration();
  addMRFrameworkToDistributedCache(conf);
  // 创建一个临时路径
  Path jobStagingArea = JobSubmissionFiles.getStagingDir(cluster, conf);
  //configure the command line options correctly on the submitting dfs
  InetAddress ip = InetAddress.getLocalHost();
  if (ip != null) {
    submitHostAddress = ip.getHostAddress();
    submitHostName = ip.getHostName();
    conf.set(MRJobConfig.JOB_SUBMITHOST,submitHostName);
    conf.set(MRJobConfig.JOB_SUBMITHOSTADDR,submitHostAddress);
  }
  // 获取JobID,每个job都有自己独一无二的ID
  JobID jobId = submitClient.getNewJobID();
  job.setJobID(jobId);
  Path submitJobDir = new Path(jobStagingArea, jobId.toString());
  JobStatus status = null;
  try {
    conf.set(MRJobConfig.USER_NAME,
        UserGroupInformation.getCurrentUser().getShortUserName());
    conf.set("hadoop.http.filter.initializers", 
        "org.apache.hadoop.yarn.server.webproxy.amfilter.AmFilterInitializer");
    conf.set(MRJobConfig.MAPREDUCE_JOB_DIR, submitJobDir.toString());
    LOG.debug("Configuring job " + jobId + " with " + submitJobDir 
        + " as the submit dir");
    // get delegation token for the dir

    // generate a secret to authenticate shuffle transfers

    // Create the splits for the job
    LOG.debug("Creating splits at " + jtFs.makeQualified(submitJobDir));
    // 重要：切片
    int maps = writeSplits(job, submitJobDir);
    conf.setInt(MRJobConfig.NUM_MAPS, maps);
    LOG.info("number of splits:" + maps);

    int maxMaps = conf.getInt(MRJobConfig.JOB_MAX_MAP,
        MRJobConfig.DEFAULT_JOB_MAX_MAP);
    if (maxMaps >= 0 && maxMaps < maps) {
      throw new IllegalArgumentException("The number of map tasks " + maps +
          " exceeded limit " + maxMaps);
    }

    // ...省略其他代码信息
}
```
我们重点看一下切片个数计算逻辑：
```java
// 切片数计算
int maps = writeSplits(job, submitJobDir);

private int writeSplits(org.apache.hadoop.mapreduce.JobContext job,
                        Path jobSubmitDir) throws IOException,
								InterruptedException, ClassNotFoundException {
    JobConf jConf = (JobConf)job.getConfiguration();
    int maps;
    if (jConf.getUseNewMapper()) {
        // 获取切片数
        maps = writeNewSplits(job, jobSubmitDir);
    } else {
        maps = writeOldSplits(jConf, jobSubmitDir);
    }
    return maps;
}
// maps = writeNewSplits(job, jobSubmitDir);
private <T extends InputSplit>
    int writeNewSplits(JobContext job, Path jobSubmitDir) throws IOException,
InterruptedException, ClassNotFoundException {
    Configuration conf = job.getConfiguration();
    InputFormat<?, ?> input =
        ReflectionUtils.newInstance(job.getInputFormatClass(), conf);
    // 此处进行切分
    List<InputSplit> splits = input.getSplits(job);
    T[] array = (T[]) splits.toArray(new InputSplit[splits.size()]);

    // sort the splits into order based on size, so that the biggest
    // go first
    Arrays.sort(array, new SplitComparator());
    // 将切片信息写入到临时文件中
    JobSplitWriter.createSplitFiles(jobSubmitDir, conf, 
                                    jobSubmitDir.getFileSystem(conf), array);
    return array.length;
}
// 切片个数计算
public List<InputSplit> getSplits(JobContext job) throws IOException {
    StopWatch sw = new StopWatch().start();
    // minSize默认是1
    long minSize = Math.max(getFormatMinSplitSize(), getMinSplitSize(job));
    // maxSize默认是Long类型的最大值
    long maxSize = getMaxSplitSize(job);

    // generate splits
    List<InputSplit> splits = new ArrayList<InputSplit>();
    List<FileStatus> files = listStatus(job);

    boolean ignoreDirs = !getInputDirRecursive(job)
        && job.getConfiguration().getBoolean(INPUT_DIR_NONRECURSIVE_IGNORE_SUBDIRS, false);
    // 循环遍历输入路径下的所有文件，每个文件单独进行切分
    for (FileStatus file: files) {
        if (ignoreDirs && file.isDirectory()) {
            continue;
        }
        Path path = file.getPath();
        long length = file.getLen();
        if (length != 0) {
            BlockLocation[] blkLocations;
            if (file instanceof LocatedFileStatus) {
                blkLocations = ((LocatedFileStatus) file).getBlockLocations();
            } else {
                FileSystem fs = path.getFileSystem(job.getConfiguration());
                blkLocations = fs.getFileBlockLocations(file, 0, length);
            }
            if (isSplitable(job, path)) { // 文件是否可切分
                // 如果是本地集群是32M，yarn集群则是配置的128M
                long blockSize = file.getBlockSize();
                // 计算切片的大小
                // 本地环境blockSize = 32M
                // return Math.max(minSize = 1, Math.min(maxSize = Long最大值, blockSize = 32M));
                // 我们获取到的切片大小就是blockSize
                long splitSize = computeSplitSize(blockSize, minSize, maxSize); // 32M

                long bytesRemaining = length;
                // 这里就是根据切片大小实际进行文件分片了
                // ((double) bytesRemaining)/splitSize > SPLIT_SLOP
                // SPLIT_SLOP是1.1
                // 只有当剩余文件大小 > 切片的1.1倍才会将剩余的文件进行分片，否则将不会切分最后一片
                // 例如，剩余文件大小 = 33M,切片大小是32M，最后一个切片大小就是33M
                // 如果切分成1M和32M，那么对于1M的文件不利于后续的运算。
                while (((double) bytesRemaining)/splitSize > SPLIT_SLOP) {
                    int blkIndex = getBlockIndex(blkLocations, length-bytesRemaining);
                    splits.add(makeSplit(path, length-bytesRemaining, splitSize,
                                         blkLocations[blkIndex].getHosts(),
                                         blkLocations[blkIndex].getCachedHosts()));
                    bytesRemaining -= splitSize;
                }

                if (bytesRemaining != 0) {
                    int blkIndex = getBlockIndex(blkLocations, length-bytesRemaining);
                    splits.add(makeSplit(path, length-bytesRemaining, bytesRemaining,
                                         blkLocations[blkIndex].getHosts(),
                                         blkLocations[blkIndex].getCachedHosts()));
                }
            } else { // not splitable
                if (LOG.isDebugEnabled()) {
                    // Log only if the file is big enough to be splitted
                    if (length > Math.min(file.getBlockSize(), minSize)) {
                        LOG.debug("File is not splittable so no parallelization "
                                  + "is possible: " + file.getPath());
                    }
                }
                splits.add(makeSplit(path, 0, length, blkLocations[0].getHosts(),
                                     blkLocations[0].getCachedHosts()));
            }
        } else { 
            //Create empty hosts array for zero length files
            splits.add(makeSplit(path, 0, length, new String[0]));
        }
    }
    // Save the number of input files for metrics/loadgen
    job.getConfiguration().setLong(NUM_INPUT_FILES, files.size());
    sw.stop();
    if (LOG.isDebugEnabled()) {
        LOG.debug("Total # of splits generated by getSplits: " + splits.size()
                  + ", TimeTaken: " + sw.now(TimeUnit.MILLISECONDS));
    }
    return splits;
}
```

整个输入文件切分的逻辑很清晰，流程总结如下：

* 程序先找到输入数据的存储目录
* 遍历输入文件目录下的所有文件
* 获取文件大小，计算切片大小。默认情况下，切片大小等于块大小。
* 每次切分首先判断剩余文件大小是否大于切片大小的1.1倍，大于则切，否则不切；
* 完成所有文件的切分之后，将切片信息写到一个切片规划文件中；

整个切片的核心过程是在getSplit()方法中完成的，InputSplit只是记录了切片的元数据信息，例如起始位置、长度以及所在的节点列表等。

最后，客户端将提交Job信息（包括切片规划文件）到yarn上，yarn上的AppMaster就可以根据切片规划文件开启MapTask个数。

那么，我们如何调整切片的大小呢？

```java
long blockSize = file.getBlockSize();
// 计算切片的大小
// 本地环境blockSize = 32M
// return Math.max(minSize = 1, Math.min(maxSize = Long最大值, blockSize = 32M));
// 我们获取到的切片大小就是blockSize
long splitSize = computeSplitSize(blockSize, minSize, maxSize); // 32M
```

如果我们想要调大切片的大小：将minSize调大；

如果我们想要调小切片的大小：将maxSize调小；
```java
mapreduce.input.fileinputformat.split.minsize=1 // 默认值为1 
mapreduce.input.fileinputformat.split.maxsize= Long.MAX_VALUE // 默认值Long.MAX_VALUE
```
