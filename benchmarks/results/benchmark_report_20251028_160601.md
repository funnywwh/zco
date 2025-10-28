# ZCO vs Go HTTP Server Performance Benchmark

**Test Date:** 2025年 10月 28日 星期二 16:06:22 CST
**Test Environment:** Linux winger-PC 6.12.41-amd64-desktop-rolling #25.01.01.03 SMP PREEMPT_DYNAMIC Tue Aug  5 14:55:25 CST 2025 x86_64 GNU/Linux

## Test Configuration

- **ZCO Server Port:** 8080
- **Go Server Port:** 8081
- **Test Tool:** ApacheBench (ab)

## Results Summary

| Test Case | Server | Requests | Concurrency | RPS | Avg Time (ms) | Failed Requests |
|-----------|--------|----------|-------------|-----|---------------|-----------------|
| 1000/10 | ZCO | 1000 | 10 | 46500.81 | 0.215 | 0 |
| 1000/10 | Go | 1000 | 10 | 45000.45 | 0.222 | 0 |
| 10000/100 | ZCO | 10000 | 100 | 55064.26 | 1.816 | 0 |
| 10000/100 | Go | 10000 | 100 | 57931.72 | 1.726 | 0 |
| 50000/500 | ZCO | 50000 | 500 | 52028.54 | 9.610 | 0 |
| 50000/500 | Go | 50000 | 500 | 53238.44 | 9.392 | 0 |
| 100000/1000 | ZCO | 100000 | 1000 | 49044.54 | 20.390 | 0 |
| 100000/1000 | Go | 100000 | 1000 | 55756.03 | 17.935 | 0 |

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
Time taken for tests:   0.022 seconds
Complete requests:      1000
Failed requests:        0
Total transferred:      94000 bytes
HTML transferred:       10000 bytes
Requests per second:    46500.81 [#/sec] (mean)
Time per request:       0.215 [ms] (mean)
Time per request:       0.022 [ms] (mean, across all concurrent requests)
Transfer rate:          4268.63 [Kbytes/sec] received

Connection Times (ms)
              min  mean[+/-sd] median   max
Connect:        0    0   0.0      0       0
Processing:     0    0   0.0      0       0
Waiting:        0    0   0.0      0       0
Total:          0    0   0.0      0       0

Percentage of the requests served within a certain time (ms)
  50%      0
  66%      0
  75%      0
  80%      0
  90%      0
  95%      0
  98%      0
  99%      0
 100%      0 (longest request)
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
Time taken for tests:   0.022 seconds
Complete requests:      1000
Failed requests:        0
Total transferred:      113000 bytes
HTML transferred:       11000 bytes
Requests per second:    45000.45 [#/sec] (mean)
Time per request:       0.222 [ms] (mean)
Time per request:       0.022 [ms] (mean, across all concurrent requests)
Transfer rate:          4965.87 [Kbytes/sec] received

Connection Times (ms)
              min  mean[+/-sd] median   max
Connect:        0    0   0.0      0       1
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
Time taken for tests:   0.182 seconds
Complete requests:      10000
Failed requests:        0
Total transferred:      940000 bytes
HTML transferred:       100000 bytes
Requests per second:    55064.26 [#/sec] (mean)
Time per request:       1.816 [ms] (mean)
Time per request:       0.018 [ms] (mean, across all concurrent requests)
Transfer rate:          5054.73 [Kbytes/sec] received

Connection Times (ms)
              min  mean[+/-sd] median   max
Connect:        0    1   0.2      1       2
Processing:     0    1   0.2      1       2
Waiting:        0    1   0.2      1       2
Total:          1    2   0.3      2       4

Percentage of the requests served within a certain time (ms)
  50%      2
  66%      2
  75%      2
  80%      2
  90%      2
  95%      3
  98%      3
  99%      3
 100%      4 (longest request)
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
Time taken for tests:   0.173 seconds
Complete requests:      10000
Failed requests:        0
Total transferred:      1130000 bytes
HTML transferred:       110000 bytes
Requests per second:    57931.72 [#/sec] (mean)
Time per request:       1.726 [ms] (mean)
Time per request:       0.017 [ms] (mean, across all concurrent requests)
Transfer rate:          6392.86 [Kbytes/sec] received

Connection Times (ms)
              min  mean[+/-sd] median   max
Connect:        0    1   0.2      1       2
Processing:     0    1   0.3      1       3
Waiting:        0    1   0.3      1       3
Total:          0    2   0.4      2       4

Percentage of the requests served within a certain time (ms)
  50%      2
  66%      2
  75%      2
  80%      2
  90%      2
  95%      2
  98%      3
  99%      3
 100%      4 (longest request)
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
Time taken for tests:   0.961 seconds
Complete requests:      50000
Failed requests:        0
Total transferred:      4700000 bytes
HTML transferred:       500000 bytes
Requests per second:    52028.54 [#/sec] (mean)
Time per request:       9.610 [ms] (mean)
Time per request:       0.019 [ms] (mean, across all concurrent requests)
Transfer rate:          4776.06 [Kbytes/sec] received

Connection Times (ms)
              min  mean[+/-sd] median   max
Connect:        0    4   0.9      4       8
Processing:     2    5   1.3      5      12
Waiting:        0    4   1.2      4      11
Total:          6   10   1.4      9      16

Percentage of the requests served within a certain time (ms)
  50%      9
  66%     10
  75%     11
  80%     11
  90%     11
  95%     12
  98%     13
  99%     13
 100%     16 (longest request)
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
Time taken for tests:   0.939 seconds
Complete requests:      50000
Failed requests:        0
Total transferred:      5650000 bytes
HTML transferred:       550000 bytes
Requests per second:    53238.44 [#/sec] (mean)
Time per request:       9.392 [ms] (mean)
Time per request:       0.019 [ms] (mean, across all concurrent requests)
Transfer rate:          5874.95 [Kbytes/sec] received

Connection Times (ms)
              min  mean[+/-sd] median   max
Connect:        0    3   1.0      3      11
Processing:     1    6   2.4      6      29
Waiting:        0    5   2.4      4      27
Total:          4    9   2.4      9      31

Percentage of the requests served within a certain time (ms)
  50%      9
  66%     10
  75%     10
  80%     10
  90%     11
  95%     12
  98%     16
  99%     22
 100%     31 (longest request)
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
Time taken for tests:   2.039 seconds
Complete requests:      100000
Failed requests:        0
Total transferred:      9400000 bytes
HTML transferred:       1000000 bytes
Requests per second:    49044.54 [#/sec] (mean)
Time per request:       20.390 [ms] (mean)
Time per request:       0.020 [ms] (mean, across all concurrent requests)
Transfer rate:          4502.14 [Kbytes/sec] received

Connection Times (ms)
              min  mean[+/-sd] median   max
Connect:        0    9   1.6      8      18
Processing:     5   12   2.4     11      25
Waiting:        0    9   2.4      9      21
Total:         13   20   3.0     20      33

Percentage of the requests served within a certain time (ms)
  50%     20
  66%     22
  75%     22
  80%     23
  90%     24
  95%     25
  98%     26
  99%     27
 100%     33 (longest request)
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
Time taken for tests:   1.794 seconds
Complete requests:      100000
Failed requests:        0
Total transferred:      11300000 bytes
HTML transferred:       1100000 bytes
Requests per second:    55756.03 [#/sec] (mean)
Time per request:       17.935 [ms] (mean)
Time per request:       0.018 [ms] (mean, across all concurrent requests)
Transfer rate:          6152.76 [Kbytes/sec] received

Connection Times (ms)
              min  mean[+/-sd] median   max
Connect:        0    7   2.0      7      15
Processing:     5   11   2.6     10      26
Waiting:        1    8   2.4      8      22
Total:          9   18   3.5     18      34

Percentage of the requests served within a certain time (ms)
  50%     18
  66%     19
  75%     20
  80%     21
  90%     22
  95%     24
  98%     26
  99%     27
 100%     34 (longest request)
```

