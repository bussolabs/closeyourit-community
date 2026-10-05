# frozen_string_literal: true

# Add missing demo surfaces for the login persona used in product reviews (CYRA-929).
# Existing records stay untouched; example integrations never contact external services.
if Rails.env.development?
  organization = Organizations::Organization.find_by!(slug: "demo")
  admin = Accounts::Account.find_by!(email: "admin@demo.test")
  project = organization.projects.find_by!(key: "STR")
  environment = organization.environments.find_by!(code: "production")

  ApplicationRecord.transaction do
    list = Todos::List.find_or_create_by!(organization:, account: admin, name: "Codex test settimana")
    [ "Preparare la demo", "Controllare il pagamento", "Aggiornare la guida" ].each_with_index do |title, position|
      list.items.find_or_create_by!(title: "Codex test #{title}") do |item|
        item.position = position
        item.done = position == 2
      end
    end

    conversation = Chat::Conversation.find_or_create_by!(organization:, kind: :project, contextable: project) do |record|
      record.created_by = admin
      record.last_message_at = Time.current
    end
    conversation.participants.find_or_create_by!(account: admin) { |participant| participant.organization = organization }
    conversation.messages.find_or_create_by!(body: "Codex test: la demo è pronta, controlliamo insieme il checkout.") do |message|
      message.organization = organization
      message.author = admin
    end

    book = Knowledge::Book.find_or_create_by!(organization:, title: "Codex test manuale del checkout") do |record|
      record.created_by = admin
      record.description = "Le istruzioni per provare un acquisto e riconoscere gli errori."
      record.projects = [ project ]
    end
    %i[published in_review rejected].each_with_index do |status, position|
      Knowledge::Page.find_or_create_by!(organization:, publication_key: "codex-test-review-#{status}") do |page|
        page.title = "Codex test checkout #{status}"
        page.body = "Apri il carrello, controlla il totale e conferma l'acquisto. Se il pagamento fallisce, verifica che l'ordine non sia stato creato due volte."
        page.created_by = admin
        page.projects = [ project ]
        page.status = status
        page.author_kind = status == :published ? :human : :agent
        page.author_origin = "Demo locale" unless status == :published
        page.book = book if status == :published
        page.position = position
      end
    end

    review_status = organization.ticket_statuses.find_by!(review_gate: true)
    Ticketing::Ticket.find_or_create_by!(project:, title: "Codex test acquisto da approvare") do |ticket|
      ticket.reporter = admin
      ticket.reviewer = admin
      ticket.assignee = admin
      ticket.status = review_status
      ticket.priority = organization.ticket_priorities.order(:position).first!
      ticket.description = "Verificare che il riepilogo mostri lo stesso totale del carrello."
      ticket.agent_eligibility = :blocked
    end

    group = organization.groups.find_by!(name: "Storefront Suite")
    category = Product::Category.find_or_create_by!(group:, name: "Codex test acquisti") do |record|
      record.organization = organization
      record.created_by = admin
    end
    %w[Carrello Pagamento].each_with_index do |name, position|
      feature = category.features.find_or_create_by!(name: "Codex test #{name}") do |record|
        record.organization = organization
        record.created_by = admin
        record.position = position
      end
      project.platforms.each do |platform|
        feature.feature_platforms.find_or_create_by!(platform:) do |cell|
          cell.status = organization.feature_statuses.active.find_by!(category: position.zero? ? :available : :planned)
          cell.created_by = admin
        end
      end
    end

    dataset = Datasets::Dataset.find_or_create_by!(project:, name: "Codex test classificazione richieste") do |record|
      record.created_by = admin
      record.description = "Distinguere un problema da una richiesta di miglioramento."
    end
    dataset.columns.find_or_create_by!(code: "message") do |column|
      column.label = "Messaggio"
      column.kind = :text
      column.role = :input
    end
    dataset.columns.find_or_create_by!(code: "category") do |column|
      column.label = "Categoria"
      column.kind = :category
      column.role = :target
      column.options = %w[Problema Miglioramento]
      column.position = 1
    end
    [ [ "Il pagamento si blocca", "Problema" ], [ "Vorrei salvare il carrello", "Miglioramento" ] ].each_with_index do |(message, category_name), position|
      dataset.rows.find_or_create_by!(position:) do |row|
        row.cell_values = { "message" => message, "category" => category_name }
      end
    end

    %i[ok missed failing].each do |status|
      monitor = Crons::Monitor.find_or_create_by!(project:, slug: "codex-test-#{status}") do |record|
        record.name = "Codex test job #{status}"
        record.environment = environment
        record.status = status
        record.enabled = false
        record.expected_interval_minutes = 60
        record.grace_minutes = 5
        record.last_check_in_at = status == :missed ? 2.hours.ago : 5.minutes.ago
      end
      monitor.check_ins.find_or_create_by!(checked_in_at: monitor.last_check_in_at) do |check|
        check.status = status == :failing ? :fail : :ok
        check.reason = "Codex test: archivio non disponibile" if status == :failing
        check.duration_ms = 850
      end
    end

    site = Seo::Site.find_or_create_by!(project:, environment:) do |record|
      record.base_url = "https://codex-test.example.com"
      record.created_by = admin
      record.enabled = false
      record.last_audited_at = 1.hour.ago
    end
    if site.base_url == "https://codex-test.example.com"
      site.audits.find_or_create_by!(started_at: site.last_audited_at) do |audit|
        audit.status = :completed
        audit.finished_at = site.last_audited_at + 10.seconds
        audit.pages_count = 3
        audit.issues_open_count = 2
      end
      [ "/", "/catalogo", "/carrello" ].each_with_index do |path, position|
        page = site.pages.find_or_create_by!(url: "#{site.base_url}#{path}") do |record|
          record.path = path
          record.title = "Codex test #{path}"
          record.status_code = 200
          record.first_seen_at = site.last_audited_at
          record.last_seen_at = site.last_audited_at
          record.h1s = position == 1 ? [] : [ "Codex test acquisti" ]
          record.robots_directives = "noindex, follow" if position == 2
          record.word_count = 300
          record.response_time_ms = 150
        end
        next if position.zero?

        site.issues.find_or_create_by!(page:, check_key: position == 1 ? "missing_h1" : "noindex") do |issue|
          issue.severity = position == 1 ? :high : :critical
          issue.first_seen_at = site.last_audited_at
          issue.last_seen_at = site.last_audited_at
          issue.evidence = { "url" => page.url, "found" => position == 1 ? 0 : "noindex", "expected" => position == 1 ? 1 : "index" }
        end
      end
    end

    Alerting::Channel.find_or_create_by!(organization:, name: "Codex test webhook disattivato") do |channel|
      channel.created_by = admin
      channel.enabled = false
      channel.config = { "url" => "https://example.com/codex-test" }
    end

    Uptime::Group.find_or_create_by!(organization:, slug: "codex-test-status") do |status_group|
      status_group.name = "Codex test stato dei servizi"
      status_group.created_by = admin
      status_group.public_status_enabled = true
    end

    metric = Metrics::Group.find_or_create_by!(project:, fingerprint: "codex-test-checkout") do |record|
      record.title = "Codex test checkout"
      record.kind = :slow_method
      record.samples_count = 3
      record.duration_total_ms = 4_200
      record.duration_min_ms = 800
      record.duration_max_ms = 2_000
      record.first_seen_at = 61.minutes.ago
      record.last_seen_at = 1.minute.ago
    end
    [ 800, 1_400, 2_000 ].each_with_index do |duration, position|
      metric.samples.find_or_create_by!(sample_id: "codex-test-checkout-#{position}") do |sample|
        sample.project = project
        sample.kind = :slow_method
        sample.environment = environment.code
        sample.duration_ms = duration
        sample.occurred_at = metric.first_seen_at + position * 30.minutes
      end
    end

    replay = Replays::Session.find_or_create_by!(project:, replay_session_id: "codex-test-checkout") do |session|
      session.started_at = 5.minutes.ago
      session.ended_at = session.started_at + 5.seconds
      session.duration_ms = 5_000
      session.environment = environment.code
      session.user_hash = "Codex test visitatore"
      session.entry_path = session.last_path = "/codex-test-checkout"
      session.pages = [ session.entry_path ]
      session.events_count = 3
    end
    unless replay.chunks.attached?
      # A self-contained rrweb recording: no real visitor data or remote page assets.
      timestamp = (replay.started_at.to_f * 1_000).to_i
      document = { type: 0, id: 1, childNodes: [
        { type: 1, id: 2, name: "html", publicId: "", systemId: "" },
        { type: 2, id: 3, tagName: "html", attributes: {}, childNodes: [
          { type: 2, id: 4, tagName: "head", attributes: {}, childNodes: [] },
          { type: 2, id: 5, tagName: "body", attributes: {}, childNodes: [
            { type: 2, id: 6, tagName: "h1", attributes: {}, childNodes: [
              { type: 3, id: 7, textContent: "Codex test riepilogo acquisto" }
            ] }
          ] }
        ] }
      ] }
      events = [
        { type: 4, timestamp:, data: { href: "https://codex-test.example.com/codex-test-checkout", width: 800, height: 600 } },
        { type: 2, timestamp:, data: { node: document, initialOffset: { top: 0, left: 0 } } },
        { type: 3, timestamp: timestamp + 5_000, data: { source: 0, texts: [ { id: 7, value: "Codex test acquisto completato" } ], attributes: [], removes: [], adds: [] } }
      ]
      replay.chunks.attach(io: StringIO.new(ActiveSupport::Gzip.compress(JSON.generate(events))),
                           filename: "#{replay.replay_session_id}-0.json.gz", content_type: "application/gzip")
    end

    Secrets::Personal::Variable.find_or_create_by!(organization:, account: admin, name: "CODEX_TEST_DEMO") do |variable|
      variable.description = "Codex test: valore dimostrativo, non è una credenziale."
      variable.value = "demo-only-not-a-credential"
    end
    shared = Secrets::Shared::Variable.find_or_create_by!(organization:, name: "CODEX_TEST_DEMO") do |variable|
      variable.description = "Codex test: valore dimostrativo condiviso."
      variable.created_by = admin
    end
    shared.values.find_or_create_by!(environment:) { |value| value.value = "demo-only-not-a-credential" }
  end
end
