# Run using bin/ci

CI.run do
  step "Setup", "bin/setup --skip-server"

  # CYRA-589 — prima dei test, perché una migration che ha preso il numero di un'altra nei test non
  # si vede: il database del ramo nasce vuoto e le applica tutte. Si vede dopo, quando è già costata
  # a qualcun altro.
  step "Migrations: nessuna versione già presa", "bin/rails db:migrations:collisions"

  # CYRA-551 — i system spec restano nel giro (il verdetto locale è lo stesso di prima), ma in un
  # passo loro: aprono un browser vero e sono i più lenti della suite, quindi metterli in coda fa
  # arrivare prima il rosso di tutto il resto invece di annegarlo in mezzo ai loro minuti.
  step "Tests: RSpec (senza system spec)", %q(bundle exec rspec --exclude-pattern "spec/system/**/*_spec.rb")
  step "Tests: RSpec system (browser)", "bundle exec rspec spec/system"

  step "Style: Ruby", "bin/rubocop"

  step "Security: Gem audit", "bin/bundler-audit"
  step "Security: Importmap vulnerability audit", "bin/importmap audit"
  step "Security: Brakeman code analysis", "bin/brakeman --quiet --no-pager --exit-on-warn --exit-on-error"


  # Optional: set a green GitHub commit status to unblock PR merge.
  # Requires the `gh` CLI and `gh extension install basecamp/gh-signoff`.
  # if success?
  #   step "Signoff: All systems go. Ready for merge and deploy.", "gh signoff"
  # else
  #   failure "Signoff: CI failed. Do not merge or deploy.", "Fix the issues and try again."
  # end
end
