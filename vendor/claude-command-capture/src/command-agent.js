'use strict';

const net = require('net');
const os = require('os');
const path = require('path');

function socketPath() {
  return process.env.COMMAND_AGENT_SOCKET || path.join(os.homedir(), '.claude', 'state', 'command-agent.sock');
}

function agentCommand(command, timeoutMs = 2000) {
  return new Promise((resolve, reject) => {
    const client = net.createConnection(socketPath());
    let response = '';
    client.setEncoding('utf8');
    client.setTimeout(timeoutMs);
    client.on('connect', () => client.end(`${command}\n`));
    client.on('data', (chunk) => { response += chunk; });
    client.on('end', () => resolve(response));
    client.on('timeout', () => client.destroy(new Error('Command agent timed out')));
    client.on('error', reject);
  });
}

function notifyCommand(title, body) {
  const encodedTitle = Buffer.from(String(title), 'utf8').toString('base64');
  const encodedBody = Buffer.from(String(body), 'utf8').toString('base64');
  return agentCommand(`notify ${encodedTitle} ${encodedBody}`).catch(() => '');
}

module.exports = { agentCommand, notifyCommand, socketPath };
