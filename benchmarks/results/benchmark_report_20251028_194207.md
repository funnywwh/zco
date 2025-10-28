# ZCO vs Go HTTP Server Performance Benchmark

**Test Date:** 2025年 10月 28日 星期二 19:42:33 CST
**Test Environment:** Linux winger-PC 6.12.41-amd64-desktop-rolling #25.01.01.03 SMP PREEMPT_DYNAMIC Tue Aug  5 14:55:25 CST 2025 x86_64 GNU/Linux

## Test Configuration

- **ZCO Server Port:** 8080
- **Go Server Port:** 8081
- **Test Tool:** ApacheBench (ab)

## Results Summary

| Test Case | Server | Requests | Concurrency | RPS | Avg Time (ms) | Failed Requests |
|-----------|--------|----------|-------------|-----|---------------|-----------------|
| 1000/10 | ZCO | 1000 | 10 | 44947.86 | 0.222 | 0 |
| 1000/10 | Go | 1000 | 10 | 49761.15 | 0.201 | 0 |
| 10000/100 | ZCO | 10000 | 100 | 53476.79 | 1.870 | 0 |
| 10000/100 | Go | 10000 | 100 | 55344.94 | 1.807 | 0 |
| 50000/500 | ZCO | 50000 | 500 | 45954.19 | 10.880 | 0 |
| 50000/500 | Go | 50000 | 500 | 54452.77 | 9.182 | 0 |
| 100000/1000 | ZCO | 100000 | 1000 | 40173.63 | 24.892 | 0 |
| 100000/1000 | Go | 100000 | 1000 | 41779.84 | 23.935 | 0 |

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
Requests per second:    44947.86 [#/sec] (mean)
Time per request:       0.222 [ms] (mean)
Time per request:       0.022 [ms] (mean, across all concurrent requests)
Transfer rate:          4126.07 [Kbytes/sec] received

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
Time taken for tests:   0.020 seconds
Complete requests:      1000
Failed requests:        0
Total transferred:      113000 bytes
HTML transferred:       11000 bytes
Requests per second:    49761.15 [#/sec] (mean)
Time per request:       0.201 [ms] (mean)
Time per request:       0.020 [ms] (mean, across all concurrent requests)
Transfer rate:          5491.22 [Kbytes/sec] received

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
  98%      0
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
Time taken for tests:   0.187 seconds
Complete requests:      10000
Failed requests:        0
Total transferred:      940000 bytes
HTML transferred:       100000 bytes
Requests per second:    53476.79 [#/sec] (mean)
Time per request:       1.870 [ms] (mean)
Time per request:       0.019 [ms] (mean, across all concurrent requests)
Transfer rate:          4909.00 [Kbytes/sec] received

Connection Times (ms)
              min  mean[+/-sd] median   max
Connect:        0    1   0.3      1       2
Processing:     1    1   0.5      1       5
Waiting:        0    1   0.5      1       5
Total:          1    2   0.4      2       5

Percentage of the requests served within a certain time (ms)
  50%      2
  66%      2
  75%      2
  80%      2
  90%      2
  95%      3
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
Time taken for tests:   0.181 seconds
Complete requests:      10000
Failed requests:        0
Total transferred:      1130000 bytes
HTML transferred:       110000 bytes
Requests per second:    55344.94 [#/sec] (mean)
Time per request:       1.807 [ms] (mean)
Time per request:       0.018 [ms] (mean, across all concurrent requests)
Transfer rate:          6107.40 [Kbytes/sec] received

Connection Times (ms)
              min  mean[+/-sd] median   max
Connect:        0    1   0.2      1       1
Processing:     0    1   0.3      1       3
Waiting:        0    1   0.3      1       3
Total:          0    2   0.3      2       4

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
Time taken for tests:   1.088 seconds
Complete requests:      50000
Failed requests:        0
Total transferred:      4700000 bytes
HTML transferred:       500000 bytes
Requests per second:    45954.19 [#/sec] (mean)
Time per request:       10.880 [ms] (mean)
Time per request:       0.022 [ms] (mean, across all concurrent requests)
Transfer rate:          4218.45 [Kbytes/sec] received

Connection Times (ms)
              min  mean[+/-sd] median   max
Connect:        0    5   1.1      4       9
Processing:     2    6   1.6      6      11
Waiting:        0    5   1.5      4      10
Total:          5   11   1.7     11      15

Percentage of the requests served within a certain time (ms)
  50%     11
  66%     12
  75%     12
  80%     12
  90%     13
  95%     13
  98%     14
  99%     14
 100%     15 (longest request)
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
Time taken for tests:   0.918 seconds
Complete requests:      50000
Failed requests:        0
Total transferred:      5650000 bytes
HTML transferred:       550000 bytes
Requests per second:    54452.77 [#/sec] (mean)
Time per request:       9.182 [ms] (mean)
Time per request:       0.018 [ms] (mean, across all concurrent requests)
Transfer rate:          6008.95 [Kbytes/sec] received

Connection Times (ms)
              min  mean[+/-sd] median   max
Connect:        0    3   1.4      3       9
Processing:     0    6   3.1      5      21
Waiting:        0    5   3.0      4      21
Total:          1    9   3.3      8      22

Percentage of the requests served within a certain time (ms)
  50%      8
  66%     10
  75%     11
  80%     12
  90%     13
  95%     15
  98%     19
  99%     19
 100%     22 (longest request)
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
Time taken for tests:   2.489 seconds
Complete requests:      100000
Failed requests:        0
Total transferred:      9400000 bytes
HTML transferred:       1000000 bytes
Requests per second:    40173.63 [#/sec] (mean)
Time per request:       24.892 [ms] (mean)
Time per request:       0.025 [ms] (mean, across all concurrent requests)
Transfer rate:          3687.81 [Kbytes/sec] received

Connection Times (ms)
              min  mean[+/-sd] median   max
Connect:        0   10   2.2     11      19
Processing:     3   14   3.1     14      27
Waiting:        0   11   3.0     10      23
Total:         12   25   4.0     25      36

Percentage of the requests served within a certain time (ms)
  50%     25
  66%     27
  75%     28
  80%     29
  90%     30
  95%     31
  98%     32
  99%     32
 100%     36 (longest request)
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
Time taken for tests:   2.393 seconds
Complete requests:      100000
Failed requests:        0
Total transferred:      11300000 bytes
HTML transferred:       1100000 bytes
Requests per second:    41779.84 [#/sec] (mean)
Time per request:       23.935 [ms] (mean)
Time per request:       0.024 [ms] (mean, across all concurrent requests)
Transfer rate:          4610.47 [Kbytes/sec] received

Connection Times (ms)
              min  mean[+/-sd] median   max
Connect:        0    7   3.8      7      21
Processing:     0   17   9.4     14      70
Waiting:        0   14   9.6     11      66
Total:          0   24   9.0     23      76

Percentage of the requests served within a certain time (ms)
  50%     23
  66%     27
  75%     29
  80%     30
  90%     35
  95%     41
  98%     46
  99%     49
 100%     76 (longest request)
```

