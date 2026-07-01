# frozen_string_literal: true

require "bundler/gem_tasks"
require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "minitest"
  t.libs << "lib"
  t.test_files = FileList["minitest/**/*_test.rb"]
end

namespace :test do
  desc "Run the test suite with SimpleCov coverage measurement (report in coverage/)"
  task :coverage do
    ENV["COVERAGE"] = "1"
    Rake::Task["test"].invoke
  end
end

task default: :test

desc "Copy picoruby and mrbc wasm artifacts from picoruby-wasm into the gem"
task :copy_wasm do
  require "fileutils"
  require "json"

  vendor_root = File.expand_path("lib/funicular/vendor", __dir__)

  # PICORUBY_WASM_NPM_DIR overrides the default search path.
  # Default: picoruby-wasm is a sibling of picoruby-funicular under mrbgems/.
  npm_root = ENV["PICORUBY_WASM_NPM_DIR"] ||
             File.expand_path("../picoruby-wasm/npm", __dir__)

  unless Dir.exist?(npm_root)
    abort "picoruby-wasm npm directory not found: #{npm_root}\n" \
          "Set PICORUBY_WASM_NPM_DIR to override, and ensure picoruby-wasm has been built."
  end

  # ------------------------------------------------------------------
  # 1) PicoRuby runtime (browser): dist + debug
  # ------------------------------------------------------------------
  picoruby_src  = File.join(npm_root, "picoruby")
  picoruby_dest = File.join(vendor_root, "picoruby")
  abort "Missing #{picoruby_src}" unless Dir.exist?(picoruby_src)

  picoruby_version = JSON.parse(File.read(File.join(picoruby_src, "package.json"))).fetch("version")
  picoruby_files = %w[picoruby.wasm picoruby.js init.iife.js]

  %w[dist debug].each do |variant|
    src = File.join(picoruby_src, variant)
    dst = File.join(picoruby_dest, variant)
    abort "Missing source variant: #{src}" unless Dir.exist?(src)

    FileUtils.rm_rf(dst)
    FileUtils.mkdir_p(dst)
    picoruby_files.each do |fname|
      src_file = File.join(src, fname)
      abort "Missing file: #{src_file}" unless File.exist?(src_file)
      # FileUtils.copy_file follows symlinks, so debug/init.iife.js
      # (a symlink to ../dist/init.iife.js) is materialized.
      FileUtils.copy_file(src_file, File.join(dst, fname))
    end
    puts "  copied picoruby/#{variant}"
  end

  File.write(File.join(picoruby_dest, "VERSION"), "#{picoruby_version}\n")
  puts "  wrote picoruby/VERSION (#{picoruby_version})"

  # ------------------------------------------------------------------
  # 2) mrbc compiler (node CLI, run by Funicular::Compiler)
  # ------------------------------------------------------------------
  mrbc_src  = File.join(npm_root, "mrbc", "debug")
  mrbc_dest = File.join(vendor_root, "mrbc")
  abort "Missing #{mrbc_src}" unless Dir.exist?(mrbc_src)

  mrbc_version = JSON.parse(File.read(File.join(npm_root, "mrbc", "package.json"))).fetch("version")
  mrbc_files = %w[mrbc.js mrbc.wasm]

  FileUtils.rm_rf(mrbc_dest)
  FileUtils.mkdir_p(mrbc_dest)
  mrbc_files.each do |fname|
    src_file = File.join(mrbc_src, fname)
    abort "Missing file: #{src_file}" unless File.exist?(src_file)
    FileUtils.copy_file(src_file, File.join(mrbc_dest, fname))
  end
  File.chmod(0755, File.join(mrbc_dest, "mrbc.js"))
  File.write(File.join(mrbc_dest, "VERSION"), "#{mrbc_version}\n")
  puts "  copied mrbc (#{mrbc_version})"

  # ------------------------------------------------------------------
  # 3) PicoRuby runtime for DOM-backed Node.js tests
  # ------------------------------------------------------------------
  test_runtime_src = ENV["PICORUBY_WASM_TEST_DIR"] ||
                     File.expand_path("../../build/picoruby-wasm-test/bin", __dir__)
  test_runtime_dest = File.join(vendor_root, "picoruby-test-node")
  test_runtime_files = %w[picoruby.js picoruby.wasm]
  optional_test_runtime_files = %w[picoruby.wasm.map]

  unless Dir.exist?(test_runtime_src)
    abort "PicoRuby WASM test runtime not found: #{test_runtime_src}\n" \
          "Run `MRUBY_CONFIG=picoruby-wasm-test rake all` from the picoruby checkout, " \
          "or set PICORUBY_WASM_TEST_DIR to the directory containing picoruby.js."
  end

  FileUtils.rm_rf(test_runtime_dest)
  FileUtils.mkdir_p(test_runtime_dest)
  test_runtime_files.each do |fname|
    src_file = File.join(test_runtime_src, fname)
    abort "Missing file: #{src_file}" unless File.exist?(src_file)
    FileUtils.copy_file(src_file, File.join(test_runtime_dest, fname))
  end
  optional_test_runtime_files.each do |fname|
    src_file = File.join(test_runtime_src, fname)
    FileUtils.copy_file(src_file, File.join(test_runtime_dest, fname)) if File.exist?(src_file)
  end
  File.write(File.join(test_runtime_dest, "VERSION"), "#{picoruby_version}\n")
  puts "  copied picoruby-test-node (#{picoruby_version})"
end

# Make sure the wasm artifacts are refreshed before the gem is packaged for release.
Rake::Task["build"].enhance([:copy_wasm])
