# frozen_string_literal: true

# Guard N+1 (knowledge-base/stacks/rails/testing-kit.md §5) — GATE BLOCCANTE (raise = true).
#
# SCOPE: solo i **request spec**. Un request spec = una singola richiesta HTTP (il codice di
# produzione) → finestra di scan corretta per gli N+1. I **system spec sono ESCLUSI** di proposito:
# fanno navigazione multi-step (Capybara carica più pagine per example) e le query per-richiesta
# (risoluzione sessione/account in Authentication, org in OrganizationContext) si ripetono
# LEGITTIMAMENTE ad ogni pagina → prosopite le conterebbe come N+1 (falso positivo). La copertura
# N+1 dei controller è garantita dai request spec, che esercitano le stesse action con una richiesta
# per example (la show della chat, ad es., è pulita nel request spec).
#
# Il ramp log-only (raise = false) aveva contato ~1130 example con N+1, quasi tutti nel SETUP
# (seed/bootstrap scansionati insieme all'example): bonificati alla radice — Types::InstallDefaults
# via insert_all, VisibleScope memoizzato + batch per-account, Account#member_of_organization?
# memoizzato (validazioni tenant), SLA uptime a query unica, preload icone/associazioni. Vedi
# closeyourit-docs/ROADMAP.md.
require "prosopite"

Prosopite.raise = true
Prosopite.rails_logger = true
# A spec for a loop needs at least 3 records: on Rails 8.1.3 the first iteration ran on a different
# call stack, so with 2 records the repetition went unseen (Rails 8.1.4 sees it). CYRA-1048
# Bulk approval saves each card on its own on purpose (lock, validations, history, no shared
# transaction), capped at Queue::PAGE_LIMIT keys. Only that step may repeat: resolving the cards
# is one read per family and stays guarded. CYRA-1048
Prosopite.allow_stack_paths = [ %r{app/services/home/approvals/bulk_approve\.rb:\d+:in 'Home::Approvals::BulkApprove#approve'} ]

module ProsopiteHelpers
  # Eccezione puntuale e motivata (mai a tappeto): fixture bulk nel setup del request spec o secondo
  # giro di un test multi-richiesta (idempotenza) — query per-record/per-richiesta che non sono N+1
  # di produzione. Sempre con commento sul perché.
  def allow_n_plus_one
    Prosopite.pause
    yield
  ensure
    Prosopite.resume
  end
end

RSpec.configure do |config|
  config.include ProsopiteHelpers

  config.before(:each, type: :request) { Prosopite.scan }
  config.after(:each, type: :request) { Prosopite.finish }
end
