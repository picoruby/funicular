# Single source of truth for the Funicular version.
#
# This file lives in mrblib so that it is compiled into PicoRuby.wasm along
# with the rest of the runtime. The CRuby gem reuses it via
# lib/funicular/version.rb, so the version is defined in exactly one place.
#
# Keep this file free of any dependency: it must evaluate standalone in
# both PicoRuby and CRuby, regardless of load order.
module Funicular
  VERSION = '0.5.1'
end
