// Runs the shipped Markdown/TeX parser, with no dependency installation or browser.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const root = path.resolve(__dirname, '../Todex/Resources/Chat');
const markdown = require(path.join(root, 'markdown-it.min.js'))({html: false, linkify: true});
const context = {window: {}, katex: require(path.join(root, 'katex.min.js'))};
vm.runInNewContext(fs.readFileSync(path.join(root, 'math.js'), 'utf8'), context);
markdown.use(context.window.todexMath);
for (const input of ['$x^2$', '\\(x^2\\)', '$$x^2$$', '\\[x^2\\]', '$$\nx^2 + y^2\n$$', '\\[\nx^2\n\\]']) {
  assert.match(markdown.render(input), /class="katex/);
}
for (const input of ['`$x$`', '```swift\nlet price = "$x$"\n```', 'Price \\$5 and \\$10.', 'Unfinished $x', 'Unfinished \\(x']) {
  assert.doesNotMatch(markdown.render(input), /class="katex/);
}
const hostile = markdown.render('<script>alert(1)</script> [bad](javascript:alert(1))');
assert.doesNotMatch(hostile, /<script>|href="javascript:/);
assert.match(hostile, /&lt;script&gt;/);
assert.doesNotMatch(markdown.render('$\\href{javascript:alert(1)}{click}$'), /href="javascript:/);
assert.match(markdown.render('| A | B |\n| - | - |\n| 1 | 2 |'), /<table>/);
assert.doesNotMatch(markdown.render('$' + 'x'.repeat(17000) + '$'), /class="katex/);
console.log('Renderer: 6 TeX delimiters, 5 literal/code cases, HTML/link safety, table and math bound passed.');
