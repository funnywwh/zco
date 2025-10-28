# ZCO vs Go HTTP Server Performance Benchmark

**Test Date:** 2025年 10月 28日 星期二 17:07:40 CST
**Test Environment:** Linux winger-PC 6.12.41-amd64-desktop-rolling #25.01.01.03 SMP PREEMPT_DYNAMIC Tue Aug  5 14:55:25 CST 2025 x86_64 GNU/Linux

## Test Configuration

- **ZCO Server Port:** 8080
- **Go Server Port:** 8081
- **Test Tool:** ApacheBench (ab)

## Results Summary

| Test Case | Server | Requests | Concurrency | RPS | Avg Time (ms) | Failed Requests |
|-----------|--------|----------|-------------|-----|---------------|-----------------|
| 1000/10 | ZCO | 1000 | 10 | 45678.79 | 0.219 | 0 |
| 1000/10 | Go | 1000 | 10 | 39359.23 | 0.254 | 0 |
| 10000/100 | ZCO | 10000 | 100 | 50022.01 | 1.999 | 0 |
| 10000/100 | Go | 10000 | 100 | 50995.95 | 1.961 | 0 |
| 50000/500 | ZCO | 50000 | 500 | 40300.97 | 12.407 | 0 |
| 50000/500 | Go | 50000 | 500 | 42723.50 | 11.703 | 0 |
| 100000/1000 | ZCO | 100000 | 1000 | 31837.33 | 31.410 | 0 |
| 100000/1000 | Go | 100000 | 1000 | 37566.76 | 26.619 | 0 |

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
Requests per second:    45678.79 [#/sec] (mean)
Time per request:       0.219 [ms] (mean)
Time per request:       0.022 [ms] (mean, across all concurrent requests)
Transfer rate:          4193.17 [Kbytes/sec] received

Connection Times (ms)
              min  mean[+/-sd] median   max
Connect:        0    0   0.1      0       0
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
Time taken for tests:   0.025 seconds
Complete requests:      1000
Failed requests:        0
Total transferred:      113000 bytes
HTML transferred:       11000 bytes
Requests per second:    39359.23 [#/sec] (mean)
Time per request:       0.254 [ms] (mean)
Time per request:       0.025 [ms] (mean, across all concurrent requests)
Transfer rate:          4343.35 [Kbytes/sec] received

Connection Times (ms)
              min  mean[+/-sd] median   max
Connect:        0    0   0.0      0       0
Processing:     0    0   0.2      0       2
Waiting:        0    0   0.2      0       2
Total:          0    0   0.2      0       2

Percentage of the requests served within a certain time (ms)
  50%      0
  66%      0
  75%      0
  80%      0
  90%      0
  95%      1
  98%      1
  99%      1
 100%      2 (longest request)
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
Time taken for tests:   0.200 seconds
Complete requests:      10000
Failed requests:        0
Total transferred:      940000 bytes
HTML transferred:       100000 bytes
Requests per second:    50022.01 [#/sec] (mean)
Time per request:       1.999 [ms] (mean)
Time per request:       0.020 [ms] (mean, across all concurrent requests)
Transfer rate:          4591.86 [Kbytes/sec] received

Connection Times (ms)
              min  mean[+/-sd] median   max
Connect:        0    1   0.2      1       2
Processing:     0    1   0.3      1       2
Waiting:        0    1   0.3      1       2
Total:          1    2   0.4      2       3

Percentage of the requests served within a certain time (ms)
  50%      2
  66%      2
  75%      2
  80%      2
  90%      2
  95%      3
  98%      3
  99%      3
 100%      3 (longest request)
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
Time taken for tests:   0.196 seconds
Complete requests:      10000
Failed requests:        0
Total transferred:      1130000 bytes
HTML transferred:       110000 bytes
Requests per second:    50995.95 [#/sec] (mean)
Time per request:       1.961 [ms] (mean)
Time per request:       0.020 [ms] (mean, across all concurrent requests)
Transfer rate:          5627.48 [Kbytes/sec] received

Connection Times (ms)
              min  mean[+/-sd] median   max
Connect:        0    1   0.3      1       3
Processing:     0    1   0.5      1       4
Waiting:        0    1   0.5      1       4
Total:          0    2   0.5      2       5

Percentage of the requests served within a certain time (ms)
  50%      2
  66%      2
  75%      2
  80%      2
  90%      3
  95%      3
  98%      3
  99%      4
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
Time taken for tests:   1.241 seconds
Complete requests:      50000
Failed requests:        0
Total transferred:      4700000 bytes
HTML transferred:       500000 bytes
Requests per second:    40300.97 [#/sec] (mean)
Time per request:       12.407 [ms] (mean)
Time per request:       0.025 [ms] (mean, across all concurrent requests)
Transfer rate:          3699.50 [Kbytes/sec] received

Connection Times (ms)
              min  mean[+/-sd] median   max
Connect:        0    5   1.4      5      11
Processing:     1    7   1.9      7      14
Waiting:        0    5   1.8      5      12
Total:          6   12   1.6     12      20

Percentage of the requests served within a certain time (ms)
  50%     12
  66%     13
  75%     13
  80%     14
  90%     14
  95%     15
  98%     16
  99%     17
 100%     20 (longest request)
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
Time taken for tests:   1.170 seconds
Complete requests:      50000
Failed requests:        0
Total transferred:      5650000 bytes
HTML transferred:       550000 bytes
Requests per second:    42723.50 [#/sec] (mean)
Time per request:       11.703 [ms] (mean)
Time per request:       0.023 [ms] (mean, across all concurrent requests)
Transfer rate:          4714.61 [Kbytes/sec] received

Connection Times (ms)
              min  mean[+/-sd] median   max
Connect:        0    4   1.8      4      13
Processing:     2    8   3.3      7      28
Waiting:        0    6   3.2      5      26
Total:          4   12   3.7     11      29

Percentage of the requests served within a certain time (ms)
  50%     11
  66%     13
  75%     14
  80%     15
  90%     16
  95%     18
  98%     21
  99%     22
 100%     29 (longest request)
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
Time taken for tests:   3.141 seconds
Complete requests:      100000
Failed requests:        0
Total transferred:      9400000 bytes
HTML transferred:       1000000 bytes
Requests per second:    31837.33 [#/sec] (mean)
Time per request:       31.410 [ms] (mean)
Time per request:       0.031 [ms] (mean, across all concurrent requests)
Transfer rate:          2922.57 [Kbytes/sec] received

Connection Times (ms)
              min  mean[+/-sd] median   max
Connect:        0   13   5.1     12      52
Processing:     5   18   7.1     17      77
Waiting:        0   13   5.9     12      60
Total:         15   31  10.4     29      94

Percentage of the requests served within a certain time (ms)
  50%     29
  66%     30
  75%     31
  80%     32
  90%     37
  95%     54
  98%     70
  99%     87
 100%     94 (longest request)
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
Time taken for tests:   2.662 seconds
Complete requests:      100000
Failed requests:        0
Total transferred:      11300000 bytes
HTML transferred:       1100000 bytes
Requests per second:    37566.76 [#/sec] (mean)
Time per request:       26.619 [ms] (mean)
Time per request:       0.027 [ms] (mean, across all concurrent requests)
Transfer rate:          4145.55 [Kbytes/sec] received

Connection Times (ms)
              min  mean[+/-sd] median   max
Connect:        0   11   2.9     11      24
Processing:     5   16   3.6     16      36
Waiting:        0   12   3.6     12      33
Total:         14   26   4.3     26      45

Percentage of the requests served within a certain time (ms)
  50%     26
  66%     28
  75%     29
  80%     29
  90%     32
  95%     35
  98%     38
  99%     39
 100%     45 (longest request)
```

