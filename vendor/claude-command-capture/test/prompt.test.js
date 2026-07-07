'use strict';

const test = require('node:test');
const assert = require('node:assert');
const { renderTemplate, buildPrompt } = require('../src/prompt');
const { DEFAULT_SETTINGS } = require('../src/settings');

test('renderTemplate replaces known placeholders', () => {
  const out = renderTemplate('{a} and {b}', { a: 'x', b: 'y' });
  assert.strictEqual(out, 'x and y');
});

test('renderTemplate leaves unknown placeholders intact', () => {
  const out = renderTemplate('{a} {mystery}', { a: 'x' });
  assert.strictEqual(out, 'x {mystery}');
});

test('renderTemplate treats null values as unknown', () => {
  const out = renderTemplate('{a}', { a: null });
  assert.strictEqual(out, '{a}');
});

test('buildPrompt invokes the configured skill as a slash command', () => {
  const settings = { ...DEFAULT_SETTINGS, skill: 'triage-capture' };
  const prompt = buildPrompt(settings, {
    kind: 'text',
    source: 'clipboard',
    capturedAt: '2026-07-02T12:00:00Z',
    text: 'hello world',
  });
  assert.ok(prompt.startsWith('/triage-capture\n'));
  assert.ok(prompt.includes('Source: clipboard'));
  assert.ok(prompt.includes('hello world'));
  assert.ok(prompt.endsWith('\n'));
});

test('buildPrompt strips a leading slash from the configured skill', () => {
  const settings = { ...DEFAULT_SETTINGS, skill: '/triage-capture' };
  const prompt = buildPrompt(settings, { kind: 'text', source: 'text', text: 'x' });
  assert.ok(prompt.startsWith('/triage-capture'));
  assert.ok(!prompt.startsWith('//'));
});

test('buildPrompt with no skill omits the invocation line cleanly', () => {
  const settings = { ...DEFAULT_SETTINGS, skill: '' };
  const prompt = buildPrompt(settings, { kind: 'text', source: 'text', text: 'body' });
  assert.ok(!prompt.startsWith('/'));
  assert.ok(prompt.includes('body'));
});

test('buildPrompt uses the image template for image captures', () => {
  const settings = { ...DEFAULT_SETTINGS, skill: 's' };
  const prompt = buildPrompt(settings, {
    kind: 'image',
    source: 'screenshot',
    capturedAt: '2026-07-02T12:00:00Z',
    file: '/tmp/shot.png',
  });
  assert.ok(prompt.includes('/tmp/shot.png'));
  assert.ok(prompt.includes('Read that file'));
});

test('buildPrompt does not expand placeholders inside captured content', () => {
  const settings = { ...DEFAULT_SETTINGS, skill: 's', promptTemplate: '{content}' };
  const prompt = buildPrompt(settings, { kind: 'text', source: 'text', text: 'keep {file} literal' });
  assert.strictEqual(prompt, 'keep {file} literal\n');
});
