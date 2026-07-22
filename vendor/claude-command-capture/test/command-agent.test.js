'use strict';

const assert = require('assert');
const fs = require('fs');
const net = require('net');
const os = require('os');
const path = require('path');
const test = require('node:test');
const { agentCommand, notifyCommand } = require('../src/command-agent');

async function withAgent(handler, run) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'command-agent-test-'));
  const socket = path.join(dir, 'agent.sock');
  const previous = process.env.COMMAND_AGENT_SOCKET;
  process.env.COMMAND_AGENT_SOCKET = socket;
  const server = net.createServer(handler);
  await new Promise((resolve, reject) => server.listen(socket, (error) => error ? reject(error) : resolve()));
  try {
    await run();
  } finally {
    await new Promise((resolve) => server.close(resolve));
    if (previous === undefined) delete process.env.COMMAND_AGENT_SOCKET;
    else process.env.COMMAND_AGENT_SOCKET = previous;
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

test('agentCommand sends one newline-terminated command and returns response', async () => {
  await withAgent((client) => {
    client.once('data', (data) => {
      assert.strictEqual(data.toString(), 'ping\n');
      client.end('pong');
    });
  }, async () => {
    assert.strictEqual(await agentCommand('ping'), 'pong');
  });
});

test('notifyCommand sends UTF-8 title and body as base64 fields', async () => {
  await withAgent((client) => {
    client.once('data', (data) => {
      const [command, encodedTitle, encodedBody] = data.toString().trim().split(' ');
      assert.strictEqual(command, 'notify');
      assert.strictEqual(Buffer.from(encodedTitle, 'base64').toString('utf8'), 'Command');
      assert.strictEqual(Buffer.from(encodedBody, 'base64').toString('utf8'), 'Done ✓');
      client.end('ok');
    });
  }, async () => {
    assert.strictEqual(await notifyCommand('Command', 'Done ✓'), 'ok');
  });
});
