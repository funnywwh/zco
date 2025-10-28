# ZCO vs Go HTTP Server Performance Benchmark

**Test Date:** 2025年 10月 28日 星期二 19:35:19 CST
**Test Environment:** Linux winger-PC 6.12.41-amd64-desktop-rolling #25.01.01.03 SMP PREEMPT_DYNAMIC Tue Aug  5 14:55:25 CST 2025 x86_64 GNU/Linux

## Test Configuration

- **ZCO Server Port:** 8080
- **Go Server Port:** 8081
- **Test Tool:** ApacheBench (ab)

## Results Summary

| Test Case | Server | Requests | Concurrency | RPS | Avg Time (ms) | Failed Requests |
|-----------|--------|----------|-------------|-----|---------------|-----------------|
| 1000/10 | ZCO | 1000 | 10 | 44308.56 | 0.226 | 0 |
| 1000/10 | Go | 1000 | 10 | 38681.73 | 0.259 | 0 |
| 10000/100 | ZCO | 10000 | 100 | 44944.43 | 2.225 | 0 |
| 10000/100 | Go | 10000 | 100 | 54875.41 | 1.822 | 0 |
| 50000/500 | ZCO | 50000 | 500 | 43646.09 | 11.456 | 0 |
| 50000/500 | Go | 50000 | 500 | 45588.95 | 10.968 | 0 |
| 100000/1000 | ZCO | 100000 | 1000 | 36938.85 | 27.072 | 0 |
| 100000/1000 | Go | 100000 | 1000 | 39800.90 | 25.125 | 0 |

## Detailed Results

### Test Case: 1000 requests, 10 concurrent

#### ZCO Server
```
This is ApacheBench, Version 2.3 <$Revision: 1923142 $>
Copyright 1996 Adam Twiss, Zeus Technology Ltd, http://www.zeustech.net/
Licensed to The Apache Software Foundation, http://www.apache.org/

Benchmarking localhost (be patient)
Completed 100 requests
Completed 200 requests
Completed 300 requests
Completed 400 requests
Completed 500 requests
Completed 600 requests
Completed 700 requests
Completed 800 requests
Completed 900 requests
Completed 1000 requests
Finished 1000 requests


Server Software:        
Server Hostname:        localhost
Server Port:            8080

Document Path:          /
Document Length:        10 bytes

Concurrency Level:      10
Time taken for tests:   0.023 seconds
Complete requests:      1000
Failed requests:        0
Total transferred:      94000 bytes
HTML transferred:       10000 bytes
Requests per second:    44308.56 [#/sec] (mean)
Time per request:       0.226 [ms] (mean)
Time per request:       0.023 [ms] (mean, across all concurrent requests)
Transfer rate:          4067.39 [Kbytes/sec] received

Connection Times (ms)
              min  mean[+/-sd] median   max
Connect:        0    0   0.0      0       0
Processing:     0    0   0.0      0       0
Waiting:        0    0   0.0      0       0
Total:          0    0   0.1      0       1

Percentage of the requests served within a certain time (ms)
  50%      0
  66%      0
  75%      0
  80%      0
  90%      0
  95%      0
  98%      0
  99%      0
 100%      1 (longest request)
```

#### Go Server
```
This is ApacheBench, Version 2.3 <$Revision: 1923142 $>
Copyright 1996 Adam Twiss, Zeus Technology Ltd, http://www.zeustech.net/
Licensed to The Apache Software Foundation, http://www.apache.org/

Benchmarking localhost (be patient)
Completed 100 requests
Completed 200 requests
Completed 300 requests
Completed 400 requests
Completed 500 requests
Completed 600 requests
Completed 700 requests
Completed 800 requests
Completed 900 requests
Completed 1000 requests
Finished 1000 requests


Server Software:        
Server Hostname:        localhost
Server Port:            8081

Document Path:          /
Document Length:        11 bytes

Concurrency Level:      10
Time taken for tests:   0.026 seconds
Complete requests:      1000
Failed requests:        0
Total transferred:      113000 bytes
HTML transferred:       11000 bytes
Requests per second:    38681.73 [#/sec] (mean)
Time per request:       0.259 [ms] (mean)
Time per request:       0.026 [ms] (mean, across all concurrent requests)
Transfer rate:          4268.59 [Kbytes/sec] received

Connection Times (ms)
              min  mean[+/-sd] median   max
Connect:        0    0   0.0      0       0
Processing:     0    0   0.1      0       1
Waiting:        0    0   0.1      0       1
Total:          0    0   0.1      0       1

Percentage of the requests served within a certain time (ms)
  50%      0
  66%      0
  75%      0
  80%      0
  90%      0
  95%      0
  98%      1
  99%      1
 100%      1 (longest request)
```

### Test Case: 10000 requests, 100 concurrent

#### ZCO Server
```
This is ApacheBench, Version 2.3 <$Revision: 1923142 $>
Copyright 1996 Adam Twiss, Zeus Technology Ltd, http://www.zeustech.net/
Licensed to The Apache Software Foundation, http://www.apache.org/

Benchmarking localhost (be patient)
Completed 1000 requests
Completed 2000 requests
Completed 3000 requests
Completed 4000 requests
Completed 5000 requests
Completed 6000 requests
Completed 7000 requests
Completed 8000 requests
Completed 9000 requests
Completed 10000 requests
Finished 10000 requests


Server Software:        
Server Hostname:        localhost
Server Port:            8080

Document Path:          /
Document Length:        10 bytes

Concurrency Level:      100
Time taken for tests:   0.222 seconds
Complete requests:      10000
Failed requests:        0
Total transferred:      940000 bytes
HTML transferred:       100000 bytes
Requests per second:    44944.43 [#/sec] (mean)
Time per request:       2.225 [ms] (mean)
Time per request:       0.022 [ms] (mean, across all concurrent requests)
Transfer rate:          4125.76 [Kbytes/sec] received

Connection Times (ms)
              min  mean[+/-sd] median   max
Connect:        0    1   0.3      1       3
Processing:     0    1   0.7      1       5
Waiting:        0    1   0.7      1       5
Total:          1    2   0.6      2       5

Percentage of the requests served within a certain time (ms)
  50%      2
  66%      2
  75%      2
  80%      3
  90%      3
  95%      4
  98%      4
  99%      4
 100%      5 (longest request)
```

#### Go Server
```
This is ApacheBench, Version 2.3 <$Revision: 1923142 $>
Copyright 1996 Adam Twiss, Zeus Technology Ltd, http://www.zeustech.net/
Licensed to The Apache Software Foundation, http://www.apache.org/

Benchmarking localhost (be patient)
Completed 1000 requests
Completed 2000 requests
Completed 3000 requests
Completed 4000 requests
Completed 5000 requests
Completed 6000 requests
Completed 7000 requests
Completed 8000 requests
Completed 9000 requests
Completed 10000 requests
Finished 10000 requests


Server Software:        
Server Hostname:        localhost
Server Port:            8081

Document Path:          /
Document Length:        11 bytes

Concurrency Level:      100
Time taken for tests:   0.182 seconds
Complete requests:      10000
Failed requests:        0
Total transferred:      1130000 bytes
HTML transferred:       110000 bytes
Requests per second:    54875.41 [#/sec] (mean)
Time per request:       1.822 [ms] (mean)
Time per request:       0.018 [ms] (mean, across all concurrent requests)
Transfer rate:          6055.59 [Kbytes/sec] received

Connection Times (ms)
              min  mean[+/-sd] median   max
Connect:        0    1   0.2      1       3
Processing:     0    1   0.4      1       3
Waiting:        0    1   0.4      1       3
Total:          0    2   0.4      2       5

Percentage of the requests served within a certain time (ms)
  50%      2
  66%      2
  75%      2
  80%      2
  90%      2
  95%      3
  98%      3
  99%      3
 100%      5 (longest request)
```

### Test Case: 50000 requests, 500 concurrent

#### ZCO Server
```
This is ApacheBench, Version 2.3 <$Revision: 1923142 $>
Copyright 1996 Adam Twiss, Zeus Technology Ltd, http://www.zeustech.net/
Licensed to The Apache Software Foundation, http://www.apache.org/

Benchmarking localhost (be patient)
Completed 5000 requests
Completed 10000 requests
Completed 15000 requests
Completed 20000 requests
Completed 25000 requests
Completed 30000 requests
Completed 35000 requests
Completed 40000 requests
Completed 45000 requests
Completed 50000 requests
Finished 50000 requests


Server Software:        
Server Hostname:        localhost
Server Port:            8080

Document Path:          /
Document Length:        10 bytes

Concurrency Level:      500
Time taken for tests:   1.146 seconds
Complete requests:      50000
Failed requests:        0
Total transferred:      4700000 bytes
HTML transferred:       500000 bytes
Requests per second:    43646.09 [#/sec] (mean)
Time per request:       11.456 [ms] (mean)
Time per request:       0.023 [ms] (mean, across all concurrent requests)
Transfer rate:          4006.57 [Kbytes/sec] received

Connection Times (ms)
              min  mean[+/-sd] median   max
Connect:        0    5   1.3      5      12
Processing:     2    7   1.8      6      15
Waiting:        0    5   1.7      5      13
Total:          8   11   1.8     11      23

Percentage of the requests served within a certain time (ms)
  50%     11
  66%     12
  75%     12
  80%     13
  90%     13
  95%     14
  98%     15
  99%     18
 100%     23 (longest request)
```

#### Go Server
```
This is ApacheBench, Version 2.3 <$Revision: 1923142 $>
Copyright 1996 Adam Twiss, Zeus Technology Ltd, http://www.zeustech.net/
Licensed to The Apache Software Foundation, http://www.apache.org/

Benchmarking localhost (be patient)
Completed 5000 requests
Completed 10000 requests
Completed 15000 requests
Completed 20000 requests
Completed 25000 requests
Completed 30000 requests
Completed 35000 requests
Completed 40000 requests
Completed 45000 requests
Completed 50000 requests
Finished 50000 requests


Server Software:        
Server Hostname:        localhost
Server Port:            8081

Document Path:          /
Document Length:        11 bytes

Concurrency Level:      500
Time taken for tests:   1.097 seconds
Complete requests:      50000
Failed requests:        0
Total transferred:      5650000 bytes
HTML transferred:       550000 bytes
Requests per second:    45588.95 [#/sec] (mean)
Time per request:       10.968 [ms] (mean)
Time per request:       0.022 [ms] (mean, across all concurrent requests)
Transfer rate:          5030.81 [Kbytes/sec] received

Connection Times (ms)
              min  mean[+/-sd] median   max
Connect:        0    3   1.9      3      11
Processing:     0    8   4.5      7      32
Waiting:        0    7   4.6      5      31
Total:          0   11   4.3     11      32

Percentage of the requests served within a certain time (ms)
  50%     11
  66%     12
  75%     13
  80%     14
  90%     16
  95%     18
  98%     22
  99%     26
 100%     32 (longest request)
```

### Test Case: 100000 requests, 1000 concurrent

#### ZCO Server
```
This is ApacheBench, Version 2.3 <$Revision: 1923142 $>
Copyright 1996 Adam Twiss, Zeus Technology Ltd, http://www.zeustech.net/
Licensed to The Apache Software Foundation, http://www.apache.org/

Benchmarking localhost (be patient)
Completed 10000 requests
Completed 20000 requests
Completed 30000 requests
Completed 40000 requests
Completed 50000 requests
Completed 60000 requests
Completed 70000 requests
Completed 80000 requests
Completed 90000 requests
Completed 100000 requests
Finished 100000 requests


Server Software:        
Server Hostname:        localhost
Server Port:            8080

Document Path:          /
Document Length:        10 bytes

Concurrency Level:      1000
Time taken for tests:   2.707 seconds
Complete requests:      100000
Failed requests:        0
Total transferred:      9400000 bytes
HTML transferred:       1000000 bytes
Requests per second:    36938.85 [#/sec] (mean)
Time per request:       27.072 [ms] (mean)
Time per request:       0.027 [ms] (mean, across all concurrent requests)
Transfer rate:          3390.87 [Kbytes/sec] received

Connection Times (ms)
              min  mean[+/-sd] median   max
Connect:        0   11   2.1     11      22
Processing:     8   15   3.4     15      32
Waiting:        0   11   3.3     11      29
Total:         16   27   3.8     26      44

Percentage of the requests served within a certain time (ms)
  50%     26
  66%     28
  75%     29
  80%     29
  90%     32
  95%     34
  98%     37
  99%     39
 100%     44 (longest request)
```

#### Go Server
```
This is ApacheBench, Version 2.3 <$Revision: 1923142 $>
Copyright 1996 Adam Twiss, Zeus Technology Ltd, http://www.zeustech.net/
Licensed to The Apache Software Foundation, http://www.apache.org/

Benchmarking localhost (be patient)
Completed 10000 requests
Completed 20000 requests
Completed 30000 requests
Completed 40000 requests
Completed 50000 requests
Completed 60000 requests
Completed 70000 requests
Completed 80000 requests
Completed 90000 requests
Completed 100000 requests
Finished 100000 requests


Server Software:        
Server Hostname:        localhost
Server Port:            8081

Document Path:          /
Document Length:        11 bytes

Concurrency Level:      1000
Time taken for tests:   2.513 seconds
Complete requests:      100000
Failed requests:        0
Total transferred:      11300000 bytes
HTML transferred:       1100000 bytes
Requests per second:    39800.90 [#/sec] (mean)
Time per request:       25.125 [ms] (mean)
Time per request:       0.025 [ms] (mean, across all concurrent requests)
Transfer rate:          4392.09 [Kbytes/sec] received

Connection Times (ms)
              min  mean[+/-sd] median   max
Connect:        0   10   2.8     10      26
Processing:     4   15   3.6     15      44
Waiting:        0   11   3.6     11      41
Total:         14   25   4.5     24      53

Percentage of the requests served within a certain time (ms)
  50%     24
  66%     26
  75%     27
  80%     28
  90%     30
  95%     32
  98%     37
  99%     42
 100%     53 (longest request)
```

