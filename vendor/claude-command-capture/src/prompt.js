'use strict';

// Renders the settings-defined prompt template for a capture. The skill that
// processes the submission is addressed via {skillInvocation} ("/<skill>"),
// which Claude Code resolves as a slash-command/skill invocation in -p mode.

function renderTemplate(template, vars) {
  return String(template).replace(/\{(\w+)\}/g, (match, key) => {
    if (Object.prototype.hasOwnProperty.call(vars, key) && vars[key] != null) {
      return String(vars[key]);
    }
    return match;
  });
}

// capture: { kind: 'text'|'image', source, capturedAt, text?, file? }
function buildPrompt(settings, capture) {
  const skill = (settings.skill || '').trim().replace(/^\//, '');
  const template =
    capture.kind === 'image' ? settings.imagePromptTemplate : settings.promptTemplate;
  const rendered = renderTemplate(template, {
    skill,
    skillInvocation: skill ? `/${skill}` : '',
    source: capture.source || 'unknown',
    timestamp: capture.capturedAt || '',
    content: capture.text != null ? capture.text : '',
    file: capture.file != null ? capture.file : '',
  });
  return rendered.trim() + '\n';
}

module.exports = { renderTemplate, buildPrompt };
