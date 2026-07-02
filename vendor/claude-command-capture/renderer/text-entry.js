'use strict';

const input = document.getElementById('input');

function submit() {
  window.textEntry.submit(input.value);
}

document.getElementById('submit').addEventListener('click', submit);
document.getElementById('cancel').addEventListener('click', () => window.textEntry.cancel());

input.addEventListener('keydown', (event) => {
  if (event.key === 'Enter' && !event.shiftKey) {
    event.preventDefault();
    submit();
  } else if (event.key === 'Escape') {
    event.preventDefault();
    window.textEntry.cancel();
  }
});

window.addEventListener('DOMContentLoaded', () => input.focus());
input.focus();
