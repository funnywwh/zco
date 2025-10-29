# ZCO vs Go vs gnet HTTP Server Performance Benchmark

**Test Date:** 2025年 10月 29日 星期三 09:56:34 CST
**Test Environment:** Linux winger-PC 6.12.41-amd64-desktop-rolling #25.01.01.03 SMP PREEMPT_DYNAMIC Tue Aug  5 14:55:25 CST 2025 x86_64 GNU/Linux

## Test Configuration

- **ZCO Server Port:** 8080
- **Go Server Port:** 8081
- **gnet Server Port:** 8082
- **Test Tool:** ApacheBench (ab)

## Results Summary

| Test Case | Server | Requests | Concurrency | RPS | Avg Time (ms) | Failed Requests |
|-----------|--------|----------|-------------|-----|---------------|-----------------|
| 1000/10 | ZCO | 1000 | 10 | 37156.76 | 0.269 | 0 |
| 1000/10 | Go | 1000 | 10 | 34573.36 | 0.289 | 0 |
| 1000/10 | gnet | 1000 | 10 | 52642.66 | 0.190 | 0 |
| 10000/100 | ZCO | 10000 | 100 | 62875.68 | 1.590 | 0 |
| 10000/100 | Go | 10000 | 100 | 61503.64 | 1.626 | 0 |
| 10000/100 | gnet | 10000 | 100 | 63848.40 | 1.566 | 0 |
| 50000/500 | ZCO | 50000 | 500 | 59007.91 | 8.473 | 0 |
| 50000/500 | Go | 50000 | 500 | 67877.97 | 7.366 | 0 |
| 50000/500 | gnet | 50000 | 500 | 55249.11 | 9.050 | 0 |
| 100000/1000 | ZCO | 100000 | 1000 | 57801.13 | 17.301 | 0 |
| 100000/1000 | Go | 100000 | 1000 | 61273.65 | 16.320 | 0 |
| 100000/1000 | gnet | 100000 | 1000 | 63995.29 | 15.626 | 0 |

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
Time taken for tests:   0.027 seconds
Complete requests:      1000
Failed requests:        0
Total transferred:      94000 bytes
HTML transferred:       10000 bytes
Requests per second:    37156.76 [#/sec] (mean)
Time per request:       0.269 [ms] (mean)
Time per request:       0.027 [ms] (mean, across all concurrent requests)
Transfer rate:          3410.87 [Kbytes/sec] received

Connection Times (ms)
              min  mean[+/-sd] median   max
Connect:        0    0   0.0      0       0
Processing:     0    0   0.1      0       0
Waiting:        0    0   0.1      0       0
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
Time taken for tests:   0.029 seconds
Complete requests:      1000
Failed requests:        0
Total transferred:      113000 bytes
HTML transferred:       11000 bytes
Requests per second:    34573.36 [#/sec] (mean)
Time per request:       0.289 [ms] (mean)
Time per request:       0.029 [ms] (mean, across all concurrent requests)
Transfer rate:          3815.22 [Kbytes/sec] received

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

#### gnet Server
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
Server Port:            8082

Document Path:          /
Document Length:        10 bytes

Concurrency Level:      10
Time taken for tests:   0.019 seconds
Complete requests:      1000
Failed requests:        0
Total transferred:      94000 bytes
HTML transferred:       10000 bytes
Requests per second:    52642.66 [#/sec] (mean)
Time per request:       0.190 [ms] (mean)
Time per request:       0.019 [ms] (mean, across all concurrent requests)
Transfer rate:          4832.43 [Kbytes/sec] received

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
Time taken for tests:   0.159 seconds
Complete requests:      10000
Failed requests:        0
Total transferred:      940000 bytes
HTML transferred:       100000 bytes
Requests per second:    62875.68 [#/sec] (mean)
Time per request:       1.590 [ms] (mean)
Time per request:       0.016 [ms] (mean, across all concurrent requests)
Transfer rate:          5771.79 [Kbytes/sec] received

Connection Times (ms)
              min  mean[+/-sd] median   max
Connect:        0    0   0.3      0       1
Processing:     0    1   0.2      1       2
Waiting:        0    1   0.3      1       2
Total:          1    2   0.2      2       3

Percentage of the requests served within a certain time (ms)
  50%      2
  66%      2
  75%      2
  80%      2
  90%      2
  95%      2
  98%      2
  99%      2
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
Time taken for tests:   0.163 seconds
Complete requests:      10000
Failed requests:        0
Total transferred:      1130000 bytes
HTML transferred:       110000 bytes
Requests per second:    61503.64 [#/sec] (mean)
Time per request:       1.626 [ms] (mean)
Time per request:       0.016 [ms] (mean, across all concurrent requests)
Transfer rate:          6787.02 [Kbytes/sec] received

Connection Times (ms)
              min  mean[+/-sd] median   max
Connect:        0    0   0.2      1       1
Processing:     0    1   0.3      1       2
Waiting:        0    1   0.3      1       2
Total:          0    2   0.3      2       3
ERROR: The median and mean for the initial connection time are more than twice the standard
       deviation apart. These results are NOT reliable.

Percentage of the requests served within a certain time (ms)
  50%      2
  66%      2
  75%      2
  80%      2
  90%      2
  95%      2
  98%      2
  99%      2
 100%      3 (longest request)
```

#### gnet Server
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
Server Port:            8082

Document Path:          /
Document Length:        10 bytes

Concurrency Level:      100
Time taken for tests:   0.157 seconds
Complete requests:      10000
Failed requests:        0
Total transferred:      940000 bytes
HTML transferred:       100000 bytes
Requests per second:    63848.40 [#/sec] (mean)
Time per request:       1.566 [ms] (mean)
Time per request:       0.016 [ms] (mean, across all concurrent requests)
Transfer rate:          5861.08 [Kbytes/sec] received

Connection Times (ms)
              min  mean[+/-sd] median   max
Connect:        0    1   0.2      1       2
Processing:     0    1   0.2      1       2
Waiting:        0    1   0.2      1       2
Total:          1    2   0.2      1       4
ERROR: The median and mean for the total time are more than twice the standard
       deviation apart. These results are NOT reliable.

Percentage of the requests served within a certain time (ms)
  50%      1
  66%      2
  75%      2
  80%      2
  90%      2
  95%      2
  98%      2
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
Time taken for tests:   0.847 seconds
Complete requests:      50000
Failed requests:        0
Total transferred:      4700000 bytes
HTML transferred:       500000 bytes
Requests per second:    59007.91 [#/sec] (mean)
Time per request:       8.473 [ms] (mean)
Time per request:       0.017 [ms] (mean, across all concurrent requests)
Transfer rate:          5416.74 [Kbytes/sec] received

Connection Times (ms)
              min  mean[+/-sd] median   max
Connect:        0    3   0.8      4       6
Processing:     2    5   0.9      5      10
Waiting:        0    4   1.1      4       9
Total:          5    8   0.8      8      14
WARNING: The median and mean for the initial connection time are not within a normal deviation
        These results are probably not that reliable.

Percentage of the requests served within a certain time (ms)
  50%      8
  66%      9
  75%      9
  80%      9
  90%      9
  95%     10
  98%     11
  99%     12
 100%     14 (longest request)
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
Time taken for tests:   0.737 seconds
Complete requests:      50000
Failed requests:        0
Total transferred:      5650000 bytes
HTML transferred:       550000 bytes
Requests per second:    67877.97 [#/sec] (mean)
Time per request:       7.366 [ms] (mean)
Time per request:       0.015 [ms] (mean, across all concurrent requests)
Transfer rate:          7490.44 [Kbytes/sec] received

Connection Times (ms)
              min  mean[+/-sd] median   max
Connect:        0    2   1.0      2       6
Processing:     0    5   3.4      4      35
Waiting:        0    5   3.5      4      34
Total:          0    7   3.3      7      37

Percentage of the requests served within a certain time (ms)
  50%      7
  66%      8
  75%      8
  80%      9
  90%     10
  95%     12
  98%     14
  99%     19
 100%     37 (longest request)
```

#### gnet Server
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
Server Port:            8082

Document Path:          /
Document Length:        10 bytes

Concurrency Level:      500
Time taken for tests:   0.905 seconds
Complete requests:      50000
Failed requests:        0
Total transferred:      4700000 bytes
HTML transferred:       500000 bytes
Requests per second:    55249.11 [#/sec] (mean)
Time per request:       9.050 [ms] (mean)
Time per request:       0.018 [ms] (mean, across all concurrent requests)
Transfer rate:          5071.70 [Kbytes/sec] received

Connection Times (ms)
              min  mean[+/-sd] median   max
Connect:        0    4   1.5      4      13
Processing:     1    5   1.8      5      15
Waiting:        0    4   1.5      3      13
Total:          5    9   2.7      8      25

Percentage of the requests served within a certain time (ms)
  50%      8
  66%      9
  75%     10
  80%     11
  90%     12
  95%     14
  98%     20
  99%     21
 100%     25 (longest request)
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
Time taken for tests:   1.730 seconds
Complete requests:      100000
Failed requests:        0
Total transferred:      9400000 bytes
HTML transferred:       1000000 bytes
Requests per second:    57801.13 [#/sec] (mean)
Time per request:       17.301 [ms] (mean)
Time per request:       0.017 [ms] (mean, across all concurrent requests)
Transfer rate:          5305.96 [Kbytes/sec] received

Connection Times (ms)
              min  mean[+/-sd] median   max
Connect:        0    7   1.2      7      14
Processing:     5   10   1.8     10      21
Waiting:        0    8   2.0      8      18
Total:         11   17   1.9     17      27

Percentage of the requests served within a certain time (ms)
  50%     17
  66%     17
  75%     18
  80%     18
  90%     19
  95%     21
  98%     24
  99%     25
 100%     27 (longest request)
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
Time taken for tests:   1.632 seconds
Complete requests:      100000
Failed requests:        0
Total transferred:      11300000 bytes
HTML transferred:       1100000 bytes
Requests per second:    61273.65 [#/sec] (mean)
Time per request:       16.320 [ms] (mean)
Time per request:       0.016 [ms] (mean, across all concurrent requests)
Transfer rate:          6761.64 [Kbytes/sec] received

Connection Times (ms)
              min  mean[+/-sd] median   max
Connect:        0    6   1.7      6      15
Processing:     3   10   3.0     10      35
Waiting:        0    8   3.2      8      33
Total:          5   16   3.1     16      37

Percentage of the requests served within a certain time (ms)
  50%     16
  66%     17
  75%     17
  80%     18
  90%     20
  95%     22
  98%     25
  99%     28
 100%     37 (longest request)
```

#### gnet Server
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
Server Port:            8082

Document Path:          /
Document Length:        10 bytes

Concurrency Level:      1000
Time taken for tests:   1.563 seconds
Complete requests:      100000
Failed requests:        0
Total transferred:      9400000 bytes
HTML transferred:       1000000 bytes
Requests per second:    63995.29 [#/sec] (mean)
Time per request:       15.626 [ms] (mean)
Time per request:       0.016 [ms] (mean, across all concurrent requests)
Transfer rate:          5874.57 [Kbytes/sec] received

Connection Times (ms)
              min  mean[+/-sd] median   max
Connect:        0    7   1.2      7      15
Processing:     3    8   2.1      8      29
Waiting:        0    6   1.9      6      26
Total:          9   16   2.3     15      35

Percentage of the requests served within a certain time (ms)
  50%     15
  66%     16
  75%     16
  80%     16
  90%     18
  95%     19
  98%     22
  99%     25
 100%     35 (longest request)
```

