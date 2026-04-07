# frozen_string_literal: true

require "bundler/gem_tasks"
require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "minitest"
  t.libs << "lib"
  t.test_files = FileList["minitest/**/*_test.rb"]
end

task default: :test

desc "Copy picoruby and picorbc wasm artifacts from picoruby-wasm into the gem"
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
  # 2) picorbc compiler (node CLI, run by Funicular::Compiler)
  # ------------------------------------------------------------------
  picorbc_src  = File.join(npm_root, "picorbc", "debug")
  picorbc_dest = File.join(vendor_root, "picorbc")
  abort "Missing #{picorbc_src}" unless Dir.exist?(picorbc_src)

  picorbc_version = JSON.parse(File.read(File.join(npm_root, "picorbc", "package.json"))).fetch("version")
  picorbc_files = %w[picorbc.js picorbc.wasm]

  FileUtils.rm_rf(picorbc_dest)
  FileUtils.mkdir_p(picorbc_dest)
  picorbc_files.each do |fname|
    src_file = File.join(picorbc_src, fname)
    abort "Missing file: #{src_file}" unless File.exist?(src_file)
    FileUtils.copy_file(src_file, File.join(picorbc_dest, fname))
  end
  File.chmod(0755, File.join(picorbc_dest, "picorbc.js"))
  File.write(File.join(picorbc_dest, "VERSION"), "#{picorbc_version}\n")
  puts "  copied picorbc (#{picorbc_version})"
end

# Make sure the wasm artifacts are refreshed before the gem is packaged for release.
Rake::Task["build"].enhance([:copy_wasm])
