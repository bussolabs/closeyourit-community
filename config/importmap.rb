# Pin npm packages by running ./bin/importmap

pin "application"
pin "@hotwired/turbo-rails", to: "turbo.min.js"
pin "frame_missing"
pin "@hotwired/stimulus", to: "stimulus.min.js"
pin "@hotwired/stimulus-loading", to: "stimulus-loading.js"
pin_all_from "app/javascript/controllers", under: "controllers"
pin_all_from "app/javascript/lib", under: "lib"
# Loaded only by the dynamic import in the replay player: never modulepreloaded on every page (CYRA-888).
pin "rrweb-player", preload: false # @2.1.1 (bundle esbuild locale, vedi header del file vendorizzato)
