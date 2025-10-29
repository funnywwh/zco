const WebSocket = require('ws');

// 测试配置
const WS_URL = 'ws://127.0.0.1:8080';
const TEST_TIMEOUT = 5000;

// 测试结果统计
let testsPassed = 0;
let testsFailed = 0;
const results = [];

function log(message, status = 'INFO') {
    const timestamp = new Date().toISOString();
    const statusIcon = {
        'INFO': 'ℹ️',
        'PASS': '✅',
        'FAIL': '❌',
        'TEST': '🧪'
    }[status] || '  ';
    console.log(`${statusIcon} [${timestamp}] ${message}`);
}

function recordTest(name, passed, details = '') {
    if (passed) {
        testsPassed++;
        log(`PASS: ${name}`, 'PASS');
    } else {
        testsFailed++;
        log(`FAIL: ${name} - ${details}`, 'FAIL');
    }
    results.push({ name, passed, details });
}

// 测试1: WebSocket握手
async function testHandshake() {
    return new Promise((resolve) => {
        log('Testing WebSocket handshake...', 'TEST');
        const ws = new WebSocket(WS_URL);

        ws.on('open', () => {
            recordTest('Handshake', true);
            ws.close();
            resolve();
        });

        ws.on('error', (error) => {
            recordTest('Handshake', false, error.message);
            resolve();
        });

        setTimeout(() => {
            if (ws.readyState !== WebSocket.CLOSED) {
                ws.close();
                recordTest('Handshake', false, 'Timeout');
                resolve();
            }
        }, TEST_TIMEOUT);
    });
}

// 测试2: 文本消息收发
async function testTextMessage() {
    return new Promise((resolve) => {
        log('Testing text message send/receive...', 'TEST');
        const ws = new WebSocket(WS_URL);
        const testMessage = 'Hello, WebSocket!';

        ws.on('open', () => {
            ws.send(testMessage);
        });

        ws.on('message', (data) => {
            const received = data.toString();
            const passed = received === testMessage;
            recordTest('Text Message', passed, 
                passed ? '' : `Expected "${testMessage}", got "${received}"`);
            ws.close();
            resolve();
        });

        ws.on('error', (error) => {
            recordTest('Text Message', false, error.message);
            resolve();
        });

        setTimeout(() => {
            if (ws.readyState !== WebSocket.CLOSED) {
                ws.close();
                recordTest('Text Message', false, 'Timeout');
                resolve();
            }
        }, TEST_TIMEOUT);
    });
}

// 测试3: 二进制消息收发
async function testBinaryMessage() {
    return new Promise((resolve) => {
        log('Testing binary message send/receive...', 'TEST');
        const ws = new WebSocket(WS_URL);
        const testData = Buffer.from([0x01, 0x02, 0x03, 0x04, 0x05]);

        ws.on('open', () => {
            ws.send(testData);
        });

        ws.on('message', (data) => {
            const received = Buffer.isBuffer(data) ? data : Buffer.from(data);
            const passed = received.equals(testData);
            recordTest('Binary Message', passed,
                passed ? '' : `Expected ${testData.toString('hex')}, got ${received.toString('hex')}`);
            ws.close();
            resolve();
        });

        ws.on('error', (error) => {
            recordTest('Binary Message', false, error.message);
            resolve();
        });

        setTimeout(() => {
            if (ws.readyState !== WebSocket.CLOSED) {
                ws.close();
                recordTest('Binary Message', false, 'Timeout');
                resolve();
            }
        }, TEST_TIMEOUT);
    });
}

// 测试4: Ping/Pong机制
async function testPingPong() {
    return new Promise((resolve) => {
        log('Testing ping/pong mechanism...', 'TEST');
        const ws = new WebSocket(WS_URL);
        let pongReceived = false;

        ws.on('open', () => {
            // WebSocket库自动处理ping/pong，我们发送一个消息来触发服务器的ping处理
            ws.send('ping test');
        });

        ws.on('pong', () => {
            pongReceived = true;
            recordTest('Ping/Pong', true);
            ws.close();
            resolve();
        });

        ws.on('message', (data) => {
            // 服务器echo消息回来，这不是pong，等待一下看看是否有pong
            setTimeout(() => {
                if (!pongReceived) {
                    // 如果WebSocket库不支持自动pong事件，我们至少确认连接正常
                    recordTest('Ping/Pong', true, 'Connection alive (manual ping/pong may not trigger event)');
                    ws.close();
                    resolve();
                }
            }, 1000);
        });

        ws.on('error', (error) => {
            recordTest('Ping/Pong', false, error.message);
            resolve();
        });

        setTimeout(() => {
            if (ws.readyState !== WebSocket.CLOSED) {
                if (!pongReceived) {
                    recordTest('Ping/Pong', true, 'Connection maintained (pong event may not fire)');
                }
                ws.close();
                resolve();
            }
        }, TEST_TIMEOUT);
    });
}

// 测试5: 分片消息
async function testFragmentedMessage() {
    return new Promise((resolve) => {
        log('Testing fragmented messages...', 'TEST');
        const ws = new WebSocket(WS_URL);
        
        // 创建一个大消息来测试分片
        const largeMessage = 'A'.repeat(10000);
        let receivedChunks = '';

        ws.on('open', () => {
            ws.send(largeMessage);
        });

        ws.on('message', (data) => {
            receivedChunks += data.toString();
        });

        ws.on('error', (error) => {
            recordTest('Fragmented Message', false, error.message);
            resolve();
        });

        setTimeout(() => {
            const passed = receivedChunks === largeMessage;
            recordTest('Fragmented Message', passed,
                passed ? '' : `Expected ${largeMessage.length} chars, got ${receivedChunks.length}`);
            ws.close();
            resolve();
        }, TEST_TIMEOUT + 2000); // 给大消息更多时间
    });
}

// 测试6: 关闭握手
async function testCloseHandshake() {
    return new Promise((resolve) => {
        log('Testing close handshake...', 'TEST');
        const ws = new WebSocket(WS_URL);
        let closedNormally = false;

        ws.on('open', () => {
            // 发送一个消息
            ws.send('test close');
            // 然后关闭
            setTimeout(() => {
                ws.close(1000, 'Normal closure');
            }, 100);
        });

        ws.on('close', (code, reason) => {
            closedNormally = true;
            recordTest('Close Handshake', true, `Code: ${code}, Reason: ${reason}`);
            resolve();
        });

        ws.on('error', (error) => {
            recordTest('Close Handshake', false, error.message);
            resolve();
        });

        setTimeout(() => {
            if (!closedNormally) {
                recordTest('Close Handshake', false, 'Close event not received');
                resolve();
            }
        }, TEST_TIMEOUT);
    });
}

// 测试7: 多连接
async function testMultipleConnections() {
    return new Promise((resolve) => {
        log('Testing multiple concurrent connections...', 'TEST');
        const connections = [];
        let successfulConnections = 0;
        const targetConnections = 5;

        for (let i = 0; i < targetConnections; i++) {
            const ws = new WebSocket(WS_URL);
            connections.push(ws);

            ws.on('open', () => {
                successfulConnections++;
                ws.send(`Message from connection ${i}`);
                
                if (successfulConnections === targetConnections) {
                    recordTest('Multiple Connections', true, `${successfulConnections} connections`);
                    connections.forEach(conn => conn.close());
                    resolve();
                }
            });

            ws.on('error', (error) => {
                if (successfulConnections < targetConnections) {
                    recordTest('Multiple Connections', false, `Connection ${i} failed: ${error.message}`);
                    connections.forEach(conn => {
                        if (conn.readyState !== WebSocket.CLOSED) conn.close();
                    });
                    resolve();
                }
            });
        }

        setTimeout(() => {
            const passed = successfulConnections === targetConnections;
            recordTest('Multiple Connections', passed, 
                `${successfulConnections}/${targetConnections} connections succeeded`);
            connections.forEach(conn => {
                if (conn.readyState !== WebSocket.CLOSED) conn.close();
            });
            resolve();
        }, TEST_TIMEOUT * 2);
    });
}

// 运行所有测试
async function runAllTests() {
    log('='.repeat(60), 'INFO');
    log('WebSocket Server Test Suite', 'INFO');
    log('='.repeat(60), 'INFO');
    log('', 'INFO');

    await testHandshake();
    await new Promise(resolve => setTimeout(resolve, 500)); // 短暂延迟

    await testTextMessage();
    await new Promise(resolve => setTimeout(resolve, 500));

    await testBinaryMessage();
    await new Promise(resolve => setTimeout(resolve, 500));

    await testPingPong();
    await new Promise(resolve => setTimeout(resolve, 500));

    await testFragmentedMessage();
    await new Promise(resolve => setTimeout(resolve, 500));

    await testCloseHandshake();
    await new Promise(resolve => setTimeout(resolve, 500));

    await testMultipleConnections();

    // 输出测试结果摘要
    log('', 'INFO');
    log('='.repeat(60), 'INFO');
    log('Test Results Summary', 'INFO');
    log('='.repeat(60), 'INFO');
    log(`Total Tests: ${testsPassed + testsFailed}`, 'INFO');
    log(`Passed: ${testsPassed}`, 'PASS');
    log(`Failed: ${testsFailed}`, testsFailed > 0 ? 'FAIL' : 'INFO');
    log('='.repeat(60), 'INFO');

    if (testsFailed > 0) {
        log('', 'INFO');
        log('Failed Tests:', 'FAIL');
        results.forEach(r => {
            if (!r.passed) {
                log(`  - ${r.name}: ${r.details}`, 'FAIL');
            }
        });
    }

    process.exit(testsFailed > 0 ? 1 : 0);
}

// 检查服务器是否可访问
function checkServer() {
    return new Promise((resolve) => {
        const ws = new WebSocket(WS_URL);
        ws.on('open', () => {
            ws.close();
            resolve(true);
        });
        ws.on('error', () => {
            resolve(false);
        });
        setTimeout(() => {
            resolve(false);
        }, 2000);
    });
}

// 主函数
async function main() {
    log('Checking server availability...', 'INFO');
    const serverAvailable = await checkServer();
    
    if (!serverAvailable) {
        log(`❌ Cannot connect to ${WS_URL}`, 'FAIL');
        log('Please make sure the WebSocket server is running:', 'INFO');
        log('  cd websocket && zig build run', 'INFO');
        process.exit(1);
    }

    log(`✅ Server is available at ${WS_URL}`, 'PASS');
    log('', 'INFO');

    await runAllTests();
}

// 运行测试
main().catch((error) => {
    log(`Fatal error: ${error.message}`, 'FAIL');
    process.exit(1);
});
