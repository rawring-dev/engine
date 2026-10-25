#!/usr/bin/env node
'use strict';

/*
 * engine7 VS Code extension scope test.
 *
 * Tokenizes the shared fixture (and a few synthetic snippets) with
 * vscode-textmate + vscode-oniguruma -- the same Oniguruma engine VS Code
 * uses -- and asserts the TextMate scopes produced by
 * syntaxes/engine7.tmLanguage.json.
 *
 * Usage: node test/tokenize.js <plugin-dir> <fixture-path>
 * Normally invoked through test/run.sh.
 *
 * Failure output includes the 1-based fixture line, the token text, the
 * expected scope, and the actual scope stack.
 */

const fs = require('fs');
const path = require('path');

// ---------------------------------------------------------------------------
// Assertion bookkeeping
// ---------------------------------------------------------------------------

let assertions = 0;
const failures = [];

function recordFailure(message) {
  failures.push(message);
  console.error('FAIL: ' + message);
}

function check(ok, message) {
  assertions++;
  if (!ok) recordFailure(message);
}

function describeToken(token) {
  return token ? `"${token.text}" @ ${token.lineNumber}:${token.startIndex}` : '<missing>';
}

// ---------------------------------------------------------------------------
// Grammar loading / tokenization
// ---------------------------------------------------------------------------

async function loadGrammar(pluginDir, grammarPath) {
  const vsctm = require('vscode-textmate');
  const oniguruma = require('vscode-oniguruma');

  const wasmPath = require.resolve('vscode-oniguruma/release/onig.wasm');
  const wasmBytes = fs.readFileSync(wasmPath);
  const wasmBuffer = wasmBytes.buffer.slice(
    wasmBytes.byteOffset,
    wasmBytes.byteOffset + wasmBytes.byteLength
  );
  await oniguruma.loadWASM(wasmBuffer);

  const grammarText = fs.readFileSync(grammarPath, 'utf8');
  const rawGrammar = vsctm.parseRawGrammar(grammarText, grammarPath);

  const registry = new vsctm.Registry({
    onigLib: Promise.resolve({
      createOnigScanner: (sources) => new oniguruma.OnigScanner(sources),
      createOnigString: (s) => new oniguruma.OnigString(s),
    }),
    loadGrammar: async (scopeName) => {
      if (scopeName === rawGrammar.scopeName) return rawGrammar;
      return null;
    },
  });

  const grammar = await registry.loadGrammar(rawGrammar.scopeName);
  if (!grammar) {
    throw new Error(`could not load grammar for scope ${rawGrammar.scopeName}`);
  }
  return { grammar, rawGrammar, vsctm };
}

/**
 * Tokenize an array of physical lines, threading the TextMate rule stack so
 * multi-line state (strings) behaves as it does in the editor.
 */
function tokenizeLines(grammar, vsctm, lines) {
  let ruleStack = vsctm.INITIAL;
  const file = { lines: [] };
  for (let i = 0; i < lines.length; i++) {
    const text = lines[i].replace(/\r$/, '');
    const result = grammar.tokenizeLine(text, ruleStack);
    ruleStack = result.ruleStack;
    file.lines.push({
      lineNumber: i + 1,
      text,
      tokens: result.tokens.map((t) => ({
        lineNumber: i + 1,
        text: text.substring(t.startIndex, t.endIndex),
        startIndex: t.startIndex,
        endIndex: t.endIndex,
        scopes: t.scopes,
      })),
    });
  }
  return file;
}

// ---------------------------------------------------------------------------
// Scope assertions
// ---------------------------------------------------------------------------

function tokensMatching(file, lineNumber, predicate) {
  const line = file.lines[lineNumber - 1];
  if (!line) return [];
  return line.tokens.filter(predicate);
}

function expectTokenScope(file, lineNumber, tokenText, expectedScope, label) {
  assertions++;
  const line = file.lines[lineNumber - 1];
  const description = label ? `${label}: ` : '';
  if (!line) {
    recordFailure(`${description}line ${lineNumber} does not exist (wanted token "${tokenText}")`);
    return;
  }
  const matches = line.tokens.filter((t) => t.text === tokenText);
  if (matches.length !== 1) {
    recordFailure(
      `${description}line ${lineNumber}: expected exactly one token "${tokenText}", ` +
        `found ${matches.length}\n` +
        `    line:   ${line.text}\n` +
        `    tokens: ${line.tokens.map((t) => JSON.stringify(t.text)).join(' ')}`
    );
    return;
  }
  const token = matches[0];
  if (!token.scopes.includes(expectedScope)) {
    recordFailure(
      `${description}line ${lineNumber}: token "${token.text}" expected scope "${expectedScope}" ` +
        `but got [${token.scopes.join(' ')}]\n    line: ${line.text}`
    );
  }
}

function expectScopeWhere(file, lineNumber, predicate, expectedScope, label) {
  assertions++;
  const description = label ? `${label}: ` : '';
  const line = file.lines[lineNumber - 1];
  if (!line) {
    recordFailure(`${description}line ${lineNumber} does not exist`);
    return;
  }
  const matches = line.tokens.filter(predicate);
  if (matches.length === 0) {
    recordFailure(
      `${description}line ${lineNumber}: no token matched the expected pattern in ${JSON.stringify(expectedScope)}\n` +
        `    line:   ${line.text}\n` +
        `    tokens: ${line.tokens.map((t) => JSON.stringify(t.text)).join(' ')}`
    );
    return;
  }
  const bad = matches.filter((t) => !t.scopes.includes(expectedScope));
  for (const token of bad) {
    recordFailure(
      `${description}line ${lineNumber}: token "${token.text}" expected scope "${expectedScope}" ` +
        `but got [${token.scopes.join(' ')}]\n    line: ${line.text}`
    );
  }
}

function expectNoScope(file, lineNumber, tokenText, forbiddenScopePrefix, label) {
  assertions++;
  const line = file.lines[lineNumber - 1];
  const description = label ? `${label}: ` : '';
  const matches = line.tokens.filter((t) => t.text === tokenText);
  const leaked = matches.filter((t) =>
    t.scopes.some((scope) => scope.startsWith(forbiddenScopePrefix))
  );
  for (const token of leaked) {
    recordFailure(
      `${description}line ${lineNumber}: token "${token.text}" leaked scope prefix "${forbiddenScopePrefix}" ` +
        `[${token.scopes.join(' ')}]\n    line: ${line.text}`
    );
  }
}

// ---------------------------------------------------------------------------
// Expected scopes in the shared fixture
// ---------------------------------------------------------------------------

// [line, token text, expected scope, label]
const FIXTURE_EXPECTATIONS = [
  // names and declarations
  [19, 'Vec3', 'entity.name.type.engine7', 'uppercase type name'],
  [19, 'pub', 'storage.modifier.visibility.engine7', 'pub'],
  [19, 'struct', 'storage.type.declaration.engine7', 'struct'],
  [19, '<-', 'keyword.operator.assignment.engine7', 'binding operator <-'],
  [34, 'derive', 'entity.other.attribute-name.engine7', 'attribute name'],
  [34, '@', 'punctuation.definition.annotation.engine7', 'attribute @'],
  [37, 'id', 'variable.other.member.engine7', 'member in field declaration'],
  [47, '::', 'punctuation.separator.engine7', 'path separator ::'],
  [50, 'Color', 'entity.name.type.engine7', 'uppercase type name'],
  [50, 'enum', 'storage.type.declaration.engine7', 'enum'],
  [58, 'table', 'storage.type.declaration.engine7', 'table'],
  [65, 'trigger', 'storage.type.declaration.engine7', 'trigger'],
  [69, 'pair', 'entity.name.type.engine7', 'aggregate declaration name (lowercase)'],
  [69, 'where', 'keyword.other.query.engine7', 'where'],
  [73, 'trait', 'keyword.other.declaration.engine7', 'trait'],
  [73, 'Drawable', 'entity.name.type.engine7', 'trait name'],
  [73, ':', 'punctuation.separator.engine7', 'separator :'],
  [73, ';', 'punctuation.separator.engine7', 'separator ;'],
  [75, 'impl', 'keyword.other.declaration.engine7', 'impl'],
  [75, 'for', 'keyword.control.loop.engine7', 'for'],
  [85, 'inferred_error', 'variable.other.member.engine7', 'member in field declaration'],
  [85, '!', 'keyword.operator.error.engine7', 'error prefix !'],
  [86, 'optional', 'variable.other.member.engine7', 'member in field declaration'],
  [86, '?', 'keyword.operator.optional.engine7', 'optional prefix ?'],
  [87, '&', 'keyword.operator.reference.engine7', 'reference operator &'],
  [87, 'mut', 'keyword.other.modifier.engine7', 'mut'],
  [90, '*', 'keyword.operator.reference.engine7', 'reference operator *'],
  [90, 'raw', 'keyword.other.modifier.engine7', 'raw'],
  [97, 'map', 'entity.name.type.engine7', 'contextual map type before ['],
  [97, '[', 'punctuation.section.brackets.begin.engine7', 'bracket [' ],
  [97, ']', 'punctuation.section.brackets.end.engine7', 'bracket ]'],
  [109, 'normalize', 'entity.name.function.engine7', 'function declaration name'],
  [117, 'work', 'entity.name.function.engine7', 'function declaration name'],
  [117, 'async', 'keyword.other.modifier.engine7', 'async'],
  [117, 'as', 'keyword.operator.word.engine7', 'as'],
  [117, '=', 'keyword.operator.assignment.engine7', 'assignment ='],
  [126, 'update', 'entity.name.type.engine7', 'aggregate declaration name (sys)'],
  [126, 'sys', 'storage.type.declaration.engine7', 'sys'],
  [126, 'select', 'keyword.other.query.engine7', 'select'],
  [126, 'from', 'keyword.other.query.engine7', 'from'],
  [130, 'res', 'keyword.other.query.engine7', 'res'],
  [130, 'World', 'entity.name.type.engine7', 'uppercase type name'],
  [138, 'spin', 'entity.name.function.engine7', 'function declaration name'],
  [167, 'String', 'entity.name.type.engine7', 'uppercase type name'],
  [185, 'Rgb', 'entity.name.type.engine7', 'uppercase type name'],

  // strings, escapes, comments, numbers
  [228, 'tab', 'string.quoted.double.engine7', 'double-quoted string'],
  [228, '\\t', 'constant.character.escape.engine7', 'escape \\t'],
  [228, '\\n', 'constant.character.escape.engine7', 'escape \\n'],
  [228, '\\"', 'constant.character.escape.engine7', 'escape \\"'],
  [228, '\\\\', 'constant.character.escape.engine7', 'escape \\\\'],
  [229, 'single quoted', 'string.quoted.single.engine7', 'single-quoted string'],
  [225, '1_000_000', 'constant.numeric.integer.engine7', 'integer with separators'],
  [226, '6.02e23', 'constant.numeric.float.engine7', 'float with exponent'],
  [227, '1.5E-9', 'constant.numeric.float.engine7', 'float with signed exponent'],
  [147, '3', 'constant.numeric.integer.engine7', 'integer'],
  [230, 'true', 'constant.language.boolean.engine7', 'true'],
  [231, 'false', 'constant.language.boolean.engine7', 'false'],
  [209, 'nil', 'constant.language.nil.engine7', 'nil'],

  // every keyword class
  [143, 'if', 'keyword.control.conditional.engine7', 'if'],
  [170, 'elif', 'keyword.control.conditional.engine7', 'elif'],
  [172, 'else', 'keyword.control.conditional.engine7', 'else'],
  [180, 'match', 'keyword.control.conditional.engine7', 'match'],
  [141, 'loop', 'keyword.control.loop.engine7', 'loop'],
  [145, 'while', 'keyword.control.loop.engine7', 'while'],
  [161, 'for', 'keyword.control.loop.engine7', 'for'],
  [161, 'in', 'keyword.control.loop.engine7', 'in'],
  [120, 'ret', 'keyword.control.flow.engine7', 'ret'],
  [144, 'break', 'keyword.control.flow.engine7', 'break'],
  [148, 'cont', 'keyword.control.flow.engine7', 'cont'],
  [13, 'use', 'keyword.control.import.engine7', 'use'],
  [18, 'mod', 'keyword.control.import.engine7', 'mod'],
  [236, 'await', 'keyword.other.modifier.engine7', 'await'],
  [237, 'spawn', 'keyword.other.modifier.engine7', 'spawn'],
  [238, 'detach', 'keyword.other.modifier.engine7', 'detach'],
  [239, 'cancel', 'keyword.other.modifier.engine7', 'cancel'],
  [149, 'unsafe', 'keyword.other.modifier.engine7', 'unsafe'],
  [202, 'as', 'keyword.operator.word.engine7', 'as'],
  [198, 'not', 'keyword.operator.word.engine7', 'not'],
  [199, 'and', 'keyword.operator.word.engine7', 'and'],
  [200, 'or', 'keyword.operator.word.engine7', 'or'],
  [201, 'xor', 'keyword.operator.word.engine7', 'xor'],
  [13, 'crate', 'variable.language.engine7', 'crate'],
  [44, 'self', 'variable.language.engine7', 'self'],
  [15, 'super', 'variable.language.engine7', 'super'],

  // calls and fields
  [78, 'print_line', 'entity.name.function.engine7', 'function call name'],
  [78, 'id', 'variable.other.property.engine7', 'field access .id'],
  [78, '(', 'punctuation.section.parens.begin.engine7', 'paren (' ],
  [78, ')', 'punctuation.section.parens.end.engine7', 'paren )'],
  [128, 'position', 'variable.other.property.engine7', 'field access .position'],
  [128, 'velocity', 'variable.other.property.engine7', 'field access .velocity'],
  [128, '+=', 'keyword.operator.assignment.engine7', 'compound assignment +='],
  [235, 'load', 'entity.name.function.engine7', 'function call name'],
  [237, 'work', 'entity.name.function.engine7', 'function call name'],
  [19, '{', 'punctuation.section.braces.begin.engine7', 'brace {'],
  [23, '}', 'punctuation.section.braces.end.engine7', 'brace }'],
  [25, ',', 'punctuation.separator.engine7', 'separator ,'],
  [25, '->', 'keyword.operator.arrow.engine7', 'function arrow ->'],
  [161, '..', 'keyword.operator.range.engine7', 'range ..'],
  [163, '..=', 'keyword.operator.range.engine7', 'inclusive range ..='],
  [62, '...', 'punctuation.ellipsis.engine7', 'table ellipsis ...'],
  [181, '|', 'keyword.operator.pattern.engine7', 'pattern operator |'],
  [147, '==', 'keyword.operator.engine7', 'comparison =='],
  [143, '>=', 'keyword.operator.engine7', 'comparison >='],
  [145, '>', 'keyword.operator.engine7', 'comparison >'],
  [194, '+', 'keyword.operator.engine7', 'arithmetic +'],
  [183, '100.0', 'constant.numeric.float.engine7', 'float'],

  // primitive scalar type names are types, never members
  [37, 'u64', 'entity.name.type.engine7', 'primitive type u64 in field declaration'],
  [66, 'dt', 'variable.other.member.engine7', 'non-primitive member dt'],
  [66, 'f32', 'entity.name.type.engine7', 'primitive type f32 in field declaration'],
  [67, 'frame', 'variable.other.member.engine7', 'non-primitive member frame'],
  [67, 'u64', 'entity.name.type.engine7', 'primitive type u64 in field declaration'],
  [70, 'first', 'variable.other.member.engine7', 'non-primitive member first'],
  [138, 'limit', 'variable.other.member.engine7', 'non-primitive parameter is a member'],
  [218, 'str', 'entity.name.type.engine7', 'primitive type str in map key position'],
  [218, 'i32', 'entity.name.type.engine7', 'primitive type i32 in map value position'],
];

// Built-in primitive scalar type names (editors/README.md); always types.
const PRIMITIVE_TYPES = [
  'i8',
  'i16',
  'i32',
  'i64',
  'i128',
  'isize',
  'u8',
  'u16',
  'u32',
  'u64',
  'u128',
  'usize',
  'f16',
  'f32',
  'f64',
  'f128',
  'bool',
  'str',
];

// Every reserved word, with the scope class it must always receive.
const KEYWORD_SCOPES = {
  if: 'keyword.control.conditional.engine7',
  elif: 'keyword.control.conditional.engine7',
  else: 'keyword.control.conditional.engine7',
  match: 'keyword.control.conditional.engine7',
  loop: 'keyword.control.loop.engine7',
  while: 'keyword.control.loop.engine7',
  for: 'keyword.control.loop.engine7',
  in: 'keyword.control.loop.engine7',
  ret: 'keyword.control.flow.engine7',
  break: 'keyword.control.flow.engine7',
  cont: 'keyword.control.flow.engine7',
  use: 'keyword.control.import.engine7',
  mod: 'keyword.control.import.engine7',
  pub: 'storage.modifier.visibility.engine7',
  struct: 'storage.type.declaration.engine7',
  enum: 'storage.type.declaration.engine7',
  table: 'storage.type.declaration.engine7',
  trigger: 'storage.type.declaration.engine7',
  sys: 'storage.type.declaration.engine7',
  impl: 'keyword.other.declaration.engine7',
  trait: 'keyword.other.declaration.engine7',
  async: 'keyword.other.modifier.engine7',
  await: 'keyword.other.modifier.engine7',
  spawn: 'keyword.other.modifier.engine7',
  detach: 'keyword.other.modifier.engine7',
  cancel: 'keyword.other.modifier.engine7',
  unsafe: 'keyword.other.modifier.engine7',
  mut: 'keyword.other.modifier.engine7',
  raw: 'keyword.other.modifier.engine7',
  select: 'keyword.other.query.engine7',
  from: 'keyword.other.query.engine7',
  where: 'keyword.other.query.engine7',
  res: 'keyword.other.query.engine7',
  as: 'keyword.operator.word.engine7',
  not: 'keyword.operator.word.engine7',
  and: 'keyword.operator.word.engine7',
  or: 'keyword.operator.word.engine7',
  xor: 'keyword.operator.word.engine7',
  crate: 'variable.language.engine7',
  self: 'variable.language.engine7',
  super: 'variable.language.engine7',
};

const KEYWORD_SCOPE_PREFIX = /^(?:keyword|storage|variable\.language)\./;

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

async function main() {
  const pluginDir = process.argv[2]
    ? path.resolve(process.argv[2])
    : path.resolve(__dirname, '..');
  const fixturePath = process.argv[3]
    ? path.resolve(process.argv[3])
    : path.resolve(pluginDir, '..', 'samples', 'kitchen_sink.tri');

  const grammarPath = path.join(pluginDir, 'syntaxes', 'engine7.tmLanguage.json');
  const packageJsonPath = path.join(pluginDir, 'package.json');
  const languageConfigPath = path.join(pluginDir, 'language-configuration.json');
  const snippetsPath = path.join(pluginDir, 'snippets', 'engine7.json');

  // -- metadata ------------------------------------------------------------
  check(fs.existsSync(fixturePath), `shared fixture is found at ${fixturePath}`);
  check(fs.existsSync(grammarPath), `grammar file exists at ${grammarPath}`);
  check(fs.existsSync(packageJsonPath), `package.json exists at ${packageJsonPath}`);
  check(fs.existsSync(languageConfigPath), `language configuration exists at ${languageConfigPath}`);
  check(fs.existsSync(snippetsPath), `snippets exist at ${snippetsPath}`);

  const pkg = JSON.parse(fs.readFileSync(packageJsonPath, 'utf8'));
  check(pkg.name === 'engine7', `package.json name is engine7 (got ${JSON.stringify(pkg.name)})`);
  check(pkg.displayName === 'engine7', `package.json displayName is engine7`);
  check(pkg.version === '0.1.0', `package.json version is 0.1.0 (got ${JSON.stringify(pkg.version)})`);
  check(
    pkg.engines && pkg.engines.vscode === '^1.85.0',
    `package.json engines.vscode is ^1.85.0 (got ${JSON.stringify(pkg.engines && pkg.engines.vscode)})`
  );
  check(
    Array.isArray(pkg.categories) && pkg.categories.includes('Programming Languages'),
    'package.json categories include "Programming Languages"'
  );
  check(!pkg.main, 'extension is declarative (package.json has no "main" runtime entry)');
  check(!pkg.activationEvents, 'extension is declarative (package.json has no "activationEvents")');

  const languages = pkg.contributes && pkg.contributes.languages;
  const language = Array.isArray(languages) ? languages.find((l) => l.id === 'engine7') : null;
  check(!!language, 'package.json contributes language id engine7');
  if (language) {
    check(
      Array.isArray(language.aliases) && language.aliases.includes('engine7'),
      'language aliases include engine7'
    );
    check(
      Array.isArray(language.extensions) &&
        language.extensions.includes('.tri') &&
        language.extensions.includes('.e7') &&
        language.extensions.includes('.engine7'),
      'language extensions include .tri, .e7, and .engine7'
    );
    check(
      language.configuration === './language-configuration.json',
      'language configuration path is ./language-configuration.json'
    );
  }

  const grammars = pkg.contributes && pkg.contributes.grammars;
  const grammarContribution = Array.isArray(grammars)
    ? grammars.find((g) => g.language === 'engine7')
    : null;
  check(!!grammarContribution, 'package.json contributes a grammar for engine7');
  if (grammarContribution) {
    check(
      grammarContribution.scopeName === 'source.engine7',
      `package.json grammar scopeName is source.engine7 (got ${JSON.stringify(grammarContribution.scopeName)})`
    );
    check(
      grammarContribution.path === './syntaxes/engine7.tmLanguage.json',
      'package.json grammar path is ./syntaxes/engine7.tmLanguage.json'
    );
  }

  const rawGrammarText = fs.readFileSync(grammarPath, 'utf8');
  const rawGrammarJson = JSON.parse(rawGrammarText);
  check(
    rawGrammarJson.scopeName === 'source.engine7',
    `tmLanguage scopeName is source.engine7 (got ${JSON.stringify(rawGrammarJson.scopeName)})`
  );
  check(
    grammarContribution && rawGrammarJson.scopeName === grammarContribution.scopeName,
    'tmLanguage scopeName matches package.json grammar scopeName'
  );
  check(
    rawGrammarJson.name === pkg.displayName,
    `tmLanguage name matches displayName (got ${JSON.stringify(rawGrammarJson.name)})`
  );
  check(Array.isArray(rawGrammarJson.patterns) && rawGrammarJson.patterns.length > 0, 'tmLanguage has root patterns');
  check(
    rawGrammarJson.repository && typeof rawGrammarJson.repository === 'object',
    'tmLanguage has a repository'
  );

  // -- language configuration ---------------------------------------------
  const languageConfig = JSON.parse(fs.readFileSync(languageConfigPath, 'utf8'));
  check(
    languageConfig.comments && languageConfig.comments.lineComment === '#',
    'language configuration lineComment is #'
  );
  check(
    !languageConfig.comments || !languageConfig.comments.blockComment,
    'language configuration has no block comment'
  );
  check(
    Array.isArray(languageConfig.brackets) && languageConfig.brackets.length >= 3,
    'language configuration defines {} [] () brackets'
  );
  check(
    Array.isArray(languageConfig.autoClosingPairs) && languageConfig.autoClosingPairs.length >= 3,
    'language configuration defines auto-closing pairs'
  );
  check(
    Array.isArray(languageConfig.surroundingPairs) &&
      languageConfig.surroundingPairs.some((pair) => pair[0] === '"') &&
      languageConfig.surroundingPairs.some((pair) => pair[0] === "'"),
    'language configuration surrounding pairs include both string quotes'
  );
  check(
    languageConfig.indentationRules &&
      typeof languageConfig.indentationRules.increaseIndentPattern === 'string' &&
      typeof languageConfig.indentationRules.decreaseIndentPattern === 'string',
    'language configuration defines indentation rules'
  );
  if (languageConfig.indentationRules) {
    const increase = new RegExp(languageConfig.indentationRules.increaseIndentPattern);
    const decrease = new RegExp(languageConfig.indentationRules.decreaseIndentPattern);
    check(increase.test('    if value < 0:'), 'indent increases after a line ending in :');
    check(increase.test('pub normalize <- (v: Vec3) -> Vec3 {'), 'indent increases after a line ending in {');
    check(decrease.test('    }'), 'indent decreases on }');
    check(decrease.test('    ]'), 'indent decreases on ]');
    check(decrease.test('    )'), 'indent decreases on )');
    check(decrease.test('    else:'), 'indent decreases on else');
    check(decrease.test('    elif x:'), 'indent decreases on elif');
  }
  check(
    typeof languageConfig.wordPattern === 'string' && languageConfig.wordPattern.length > 0,
    'language configuration defines a wordPattern'
  );
  if (typeof languageConfig.wordPattern === 'string') {
    const wordPattern = new RegExp(languageConfig.wordPattern);
    const anchored = new RegExp('^(?:' + languageConfig.wordPattern + ')$');
    check(wordPattern.test('foo_bar9'), 'wordPattern matches engine7 identifiers');
    check(anchored.test('foo_bar9') && !anchored.test('foo-bar'), 'wordPattern covers full engine7 identifiers');
  }

  // -- snippets ------------------------------------------------------------
  const snippets = JSON.parse(fs.readFileSync(snippetsPath, 'utf8'));
  const prefixes = new Set(
    Object.values(snippets)
      .map((snippet) => (snippet && snippet.prefix) || '')
      .filter(Boolean)
  );
  for (const required of ['struct', 'enum', 'fn', 'sys', 'match', 'if']) {
    check(prefixes.has(required), `snippets define the "${required}" prefix`);
  }

  // -- grammar load + fixture tokenization ---------------------------------
  const { grammar, vsctm } = await loadGrammar(pluginDir, grammarPath);
  check(!!grammar, 'TextMate grammar loads for source.engine7');

  const fixtureText = fs.readFileSync(fixturePath, 'utf8');
  check(fixtureText.includes('engine7 kitchen sink'), 'fixture is the shared kitchen_sink.tri sample');
  const fixture = tokenizeLines(grammar, vsctm, fixtureText.split('\n'));
  check(fixture.lines.length >= 230, `fixture has at least 230 lines (got ${fixture.lines.length})`);

  // Comment: the whole first line is a # comment.
  expectScopeWhere(
    fixture,
    1,
    (token) => token.text.startsWith('#'),
    'comment.line.number-sign.engine7',
    'line comment'
  );
  check(
    tokensMatching(fixture, 1, (t) => t.text === fixture.lines[0].text).some((t) =>
      t.scopes.includes('comment.line.number-sign.engine7')
    ),
    'line 1 is fully scoped as a comment'
  );

  // Every reserved word in the fixture must get its documented scope.
  const tokensByText = new Map();
  for (const line of fixture.lines) {
    for (const token of line.tokens) {
      if (!tokensByText.has(token.text)) tokensByText.set(token.text, []);
      tokensByText.get(token.text).push(token);
    }
  }
  for (const [keyword, expectedScope] of Object.entries(KEYWORD_SCOPES)) {
    assertions++;
    const candidates = (tokensByText.get(keyword) || []).filter((token) =>
      token.scopes.some((scope) => KEYWORD_SCOPE_PREFIX.test(scope))
    );
    if (candidates.length === 0) {
      recordFailure(`keyword "${keyword}" was not found in the fixture with a keyword scope`);
      continue;
    }
    for (const token of candidates) {
      if (!token.scopes.includes(expectedScope)) {
        recordFailure(
          `keyword "${keyword}" at line ${token.lineNumber} expected scope "${expectedScope}" ` +
            `but got [${token.scopes.join(' ')}]`
        );
      }
    }
  }

  // Explicit construct assertions.
  for (const [line, text, scope, label] of FIXTURE_EXPECTATIONS) {
    expectTokenScope(fixture, line, text, scope, label);
  }

  // -- primitive scalar type names ----------------------------------------
  // The return-position i32 in `pub spin <- (limit: i32) -> i32:` must be a
  // type on both occurrences and must never fall into the member heuristic.
  expectScopeWhere(
    fixture,
    138,
    (token) => token.text === 'i32',
    'entity.name.type.engine7',
    'primitive type in parameter and return position'
  );
  expectNoScope(
    fixture,
    138,
    'i32',
    'variable.other.member.',
    'primitive excluded from the member heuristic'
  );
  expectTokenScope(fixture, 138, 'spin', 'entity.name.function.engine7', 'function declaration name');

  const primitivesFile = tokenizeLines(grammar, vsctm, [
    'types ' + PRIMITIVE_TYPES.join(' '),
    'xi32 i32x _i32 i32_ i128x',
    'i32: x',
    'dt: f32',
  ]);
  for (const primitive of PRIMITIVE_TYPES) {
    expectTokenScope(
      primitivesFile,
      1,
      primitive,
      'entity.name.type.engine7',
      'primitive scalar type name'
    );
  }
  const boundaryTokens = tokensMatching(primitivesFile, 2, (token) =>
    token.scopes.some((scope) => scope === 'entity.name.type.engine7')
  );
  check(
    boundaryTokens.length === 0,
    `primitive type names are word-boundaried (xi32/i32x must not match; matched ${JSON.stringify(
      boundaryTokens.map((t) => t.text)
    )})`
  );
  expectTokenScope(primitivesFile, 3, 'i32', 'entity.name.type.engine7', 'primitive in member position is a type');
  expectNoScope(
    primitivesFile,
    3,
    'i32',
    'variable.other.member.',
    'primitive in member position is not a member'
  );
  expectTokenScope(primitivesFile, 4, 'dt', 'variable.other.member.engine7', 'non-primitive member dt');
  expectTokenScope(primitivesFile, 4, 'f32', 'entity.name.type.engine7', 'primitive return type f32');

  // -- strings/comments must not leak across lines -------------------------
  const synthetic = tokenizeLines(grammar, vsctm, [
    'broken <- "unterminated',
    'after <- 1',
    '# a comment',
    'next <- 2',
    'if(x) {',
    'abc123 <- 1',
  ]);
  check(
    tokensMatching(synthetic, 1, (t) => t.text === 'unterminated').some((t) =>
      t.scopes.includes('string.quoted.double.engine7')
    ),
    'unterminated string opens a double-quoted string scope'
  );
  expectNoScope(synthetic, 2, 'after', 'string.', 'unterminated string does not leak to the next line');
  expectNoScope(synthetic, 2, '1', 'string.', 'unterminated string does not leak numbers');
  expectNoScope(synthetic, 4, 'next', 'comment.', 'line comment does not leak to the next line');
  expectTokenScope(synthetic, 5, 'if', 'keyword.control.conditional.engine7', 'if( stays a keyword');
  expectNoScope(synthetic, 5, 'x', 'entity.name.function.', 'identifier after if( is not a call name');
  assertions++;
  const syntheticNumbers = tokensMatching(synthetic, 6, (t) =>
    t.scopes.some((scope) => scope.startsWith('constant.numeric.'))
  );
  const syntheticNumberTexts = syntheticNumbers.map((t) => t.text);
  check(
    syntheticNumberTexts.length === 1 && syntheticNumberTexts[0] === '1',
    `digits inside identifiers are not numeric literals (got ${JSON.stringify(syntheticNumberTexts)})`
  );

  // -- results -------------------------------------------------------------
  console.log('');
  console.log(`engine7 VS Code grammar test`);
  console.log(`  fixture:    ${fixturePath}`);
  console.log(`  grammar:    ${grammarPath}`);
  console.log(`  scopeName:  ${rawGrammarJson.scopeName} (language id: engine7)`);
  if (failures.length === 0) {
    console.log(`  result:     PASS`);
    console.log(`  assertions: ${assertions}`);
    return 0;
  }
  console.log(`  result:     FAIL (${failures.length} failed assertion${failures.length === 1 ? '' : 's'})`);
  console.log(`  assertions: ${assertions} (${failures.length} failed)`);
  return 1;
}

main()
  .then((code) => {
    process.exitCode = code;
  })
  .catch((error) => {
    console.error('fatal: ' + (error && error.stack ? error.stack : error));
    process.exitCode = 1;
  });
