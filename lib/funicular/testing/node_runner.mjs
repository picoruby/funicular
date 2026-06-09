#!/usr/bin/env node

import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

const manifestPath = process.argv[2];

if (!manifestPath) {
  console.error('Usage: node node_runner.mjs <manifest.json>');
  process.exit(1);
}

const manifest = JSON.parse(readFileSync(manifestPath, 'utf8'));
const appRequire = createRequire(join(manifest.appRoot, 'package.json'));
const RESULT_MARKER = '__FUNICULAR_TEST_RESULTS_JSON__=';

let JSDOM;
try {
  ({ JSDOM } = appRequire('jsdom'));
} catch (error) {
  console.error('Funicular client tests require jsdom.');
  console.error('Install it in the Rails app with: npm install --save-dev jsdom');
  console.error(error.message);
  process.exit(1);
}

const runtimeDir = resolve(manifest.runtimeDir);
const modulePath = join(runtimeDir, 'picoruby.js');

function installDom() {
  const dom = new JSDOM(manifest.html, {
    url: manifest.url,
    pretendToBeVisual: true,
    runScripts: 'outside-only'
  });

  const win = dom.window;
  globalThis.window = win;
  globalThis.document = win.document;
  globalThis.location = win.location;
  globalThis.history = win.history;
  Object.defineProperty(globalThis, 'navigator', { value: win.navigator, configurable: true });
  Object.defineProperty(globalThis, 'localStorage', { value: win.localStorage, configurable: true });
  globalThis.Event = win.Event;
  globalThis.CustomEvent = win.CustomEvent;
  globalThis.MouseEvent = win.MouseEvent;
  globalThis.KeyboardEvent = win.KeyboardEvent;
  globalThis.InputEvent = win.InputEvent;
  globalThis.FormData = win.FormData;
  globalThis.Element = win.Element;
  globalThis.Document = win.Document;
  globalThis.HTMLElement = win.HTMLElement;
  globalThis.Node = win.Node;
  globalThis.Text = win.Text;
  globalThis.Response = globalThis.Response || win.Response;
  globalThis.fetch = globalThis.fetch || win.fetch?.bind(win);
  win.fetch = globalThis.fetch;

  return dom;
}

function rubyString(value) {
  return JSON.stringify(String(value));
}

function bootstrapRuby() {
  const sourceFiles = manifest.sourceFiles.map(rubyString).join(', ');
  const testFiles = manifest.testFiles.map(rubyString).join(', ');

  return `
require 'json'
require 'picotest'
require 'funicular'

module Funicular
  module Testing
    class DOMTest < Picotest::Test
      def setup
        JS.eval("document.body.innerHTML = '<div id=\\\\\\"app\\\\\\"></div>'")
      end

      def document
        JS.document
      end

      def container
        document.getElementById('app')
      end

      def mount(component_class, props = {})
        @component = component_class.new(props)
        @component.mount(container)
        drain
        @component
      end

      def query(selector)
        document.querySelector(selector)
      end

      def assert_selector(selector)
        actual = query(selector)
        report(!actual.nil?, "Expected selector #{selector.inspect} to exist", selector, actual)
      end

      def text(selector = nil)
        target = selector ? query(selector) : document.body
        target ? target[:textContent].to_s : ''
      end

      def assert_text(expected, selector = nil)
        actual = text(selector)
        report(
          actual.include?(expected.to_s),
          "Expected text to include #{expected.to_s.inspect}",
          expected.to_s,
          actual
        )
      end

      def dispatch(selector, event_type)
        script = "document.querySelector(" + JSON.generate(selector) + ")" \
          + ".dispatchEvent(new Event(" + JSON.generate(event_type) \
          + ", { bubbles: true, cancelable: true }))"
        JS.eval(script)
        drain
      end

      def click(selector)
        dispatch(selector, 'click')
      end

      def submit(selector = 'form')
        dispatch(selector, 'submit')
      end

      def input(selector, value)
        JS.global[:__funicularTestingValue] = value.to_s
        script = "document.querySelector(" + JSON.generate(selector) + ")" \
          + ".value = globalThis.__funicularTestingValue"
        JS.eval(script)
        dispatch(selector, 'input')
      ensure
        JS.global[:__funicularTestingValue] = nil
      end

      def drain(ms = 20)
        sleep_ms(ms) if respond_to?(:sleep_ms)
      end
    end
  end
end

source_files = [${sourceFiles}]
test_files = [${testFiles}]

(source_files + test_files).each { |file| load file }

test_classes = Object.constants.map { |name| Object.const_get(name) }.select do |klass|
  klass.class? &&
    klass != Picotest::Test &&
    klass != Funicular::Testing::DOMTest &&
    klass.ancestors.include?(Picotest::Test)
end

results = {}

test_classes.each do |klass|
  test = klass.new
  test.list_tests.each do |method_name|
    puts
    print "  #{klass}##{method_name} "
    failure_count_before = test.result["failures"].size
    exception_count_before = test.result["exceptions"].size
    begin
      test.setup
      test.send(method_name)
    rescue Picotest::Skip => e
      test.report_skip({ method: method_name.to_s, reason: e.message })
    rescue => e
      test.report_exception({ method: method_name.to_s, raise_message: "#{e.class}: #{e.message}" })
    ensure
      begin
        test.teardown
      rescue => e
        test.report_exception({ method: method_name.to_s, raise_message: "teardown #{e.class}: #{e.message}" })
      end
      test.clear_doubles
    end
    test.result["failures"][failure_count_before..-1].each do |failure|
      failure[:test] ||= "#{klass}##{method_name}"
    end
    test.result["exceptions"][exception_count_before..-1].each do |exception|
      exception[:test] ||= "#{klass}##{method_name}"
    end
  end
  results[klass.to_s] = test.result
end

puts

JS.global[:__funicularTestResult] = JSON.generate(results)
JS.global[:__funicularTestDone] = true
`;
}

function summarize(results) {
  let success = 0;
  let failures = 0;
  let exceptions = 0;
  let crashes = 0;
  let skips = 0;

  for (const [name, result] of Object.entries(results)) {
    const failureCount = result.failures?.length || 0;
    const exceptionCount = result.exceptions?.length || 0;
    const crashCount = result.crashes?.length || 0;
    const skipCount = result.skipped_count || 0;
    success += result.success_count || 0;
    failures += failureCount;
    exceptions += exceptionCount;
    crashes += crashCount;
    skips += skipCount;

    console.log(`${name}: success=${result.success_count || 0}, failure=${failureCount}, exception=${exceptionCount}, crash=${crashCount}, skip=${skipCount}`);
    for (const failure of result.failures || []) {
      const location = failure.method ? ` (${failure.method})` : '';
      console.log(`  F ${failure.test || name}${location}: ${failure.error_message}`);
      if (failure.expected !== undefined || failure.actual !== undefined) {
        console.log(`    expected: ${JSON.stringify(failure.expected)}`);
        console.log(`    actual:   ${JSON.stringify(failure.actual)}`);
      }
    }
    for (const exception of result.exceptions || []) {
      console.log(`  E ${exception.test || exception.method || name}: ${exception.raise_message}`);
    }
  }

  console.log(`Total: success=${success}, failure=${failures}, exception=${exceptions}, crash=${crashes}, skip=${skips}`);
  return failures + exceptions + crashes;
}

async function main() {
  const { default: createModule } = await import(pathToFileURL(modulePath).href);
  const Module = await createModule({
    locateFile: (file) => join(runtimeDir, file),
    print: (text) => process.stdout.write(text + '\n'),
    printErr: (text) => process.stderr.write(text + '\n')
  });

  installDom();

  const initResult = Module.ccall('picorb_init', 'number', [], []);
  if (initResult !== 0) {
    throw new Error('Failed to initialize PicoRuby');
  }

  const code = bootstrapRuby();
  const createResult = Module.ccall(
    'picorb_create_task_with_filename',
    'number',
    ['string', 'string'],
    [code, 'funicular-client-tests.rb']
  );
  if (createResult !== 0) {
    throw new Error('Failed to create Funicular test task');
  }

  const timeoutAt = Date.now() + Number(manifest.timeoutMs || 5000);
  while (!(globalThis.__funicularTestDone || globalThis.window?.__funicularTestDone) && Date.now() < timeoutAt) {
    Module.ccall('mrb_run_step', 'number', [], []);
    Module.ccall('mrb_tick_wasm', null, [], []);
    await new Promise((resolveDelay) => setTimeout(resolveDelay, 1));
  }

  if (!(globalThis.__funicularTestDone || globalThis.window?.__funicularTestDone)) {
    console.error(`Funicular client tests timed out after ${manifest.timeoutMs}ms`);
    process.exit(1);
  }

  const resultJson = globalThis.__funicularTestResult || globalThis.window?.__funicularTestResult || '{}';
  const results = JSON.parse(resultJson);
  console.log(`${RESULT_MARKER}${JSON.stringify(results)}`);
  const errorCount = summarize(results);
  process.exit(errorCount === 0 ? 0 : 1);
}

main().catch((error) => {
  console.error(error.stack || error.message || String(error));
  process.exit(1);
});
