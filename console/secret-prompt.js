'use strict';
// A prompt whose answer is not shown. On a terminal each key is read without
// being echoed; from a pipe the first line is read. The answer is returned
// to the caller and kept nowhere else.

function readHidden(question, { input = process.stdin, output = process.stdout } = {}) {
  return new Promise((resolve) => {
    output.write(question);
    let value = '';
    const finish = () => {
      if (input.isTTY) { input.setRawMode(false); }
      input.removeListener('data', onData);
      input.pause();
      output.write('\n');
      resolve(value.replace(/\r/g, '').trim());
    };
    const onData = (chunk) => {
      for (const ch of String(chunk)) {
        if (ch === '\n' || ch === '\r' || ch === '\u0004') return finish();
        if (ch === '\u0003') { value = ''; return finish(); }
        if (ch === '\u007f' || ch === '\b') value = value.slice(0, -1);
        else value += ch;
      }
    };
    if (input.isTTY) input.setRawMode(true);
    input.setEncoding('utf8');
    input.on('data', onData);
    input.resume();
  });
}

module.exports = { readHidden };
