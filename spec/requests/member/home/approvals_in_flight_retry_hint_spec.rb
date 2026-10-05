# frozen_string_literal: true

require "rails_helper"

# ── CYRA-626 ──────────────────────────────────────────────────────────────────────────────────────
#
# Quando il sistema non riesce a leggere una cosa su GitHub, la lavorazione si ferma e nessuno lo
# viene a sapere: la riga continua a dire «va avanti da sola», col pallino che pulsa e l'ultimo esito
# verde. Dall'esterno una lavorazione che sta davvero lavorando e una congelata da un guasto di rete
# si vedono identiche — l'unico modo di distinguerle è tornare a guardare dopo un'ora.
RSpec.describe "Member::Workflows — il guasto esterno si vede", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:project) { create(:project, organization: org, key: "ALFA") }
  let(:riprova_alle) { 40.minutes.from_now }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    org.update_column(:cto_id, owner.id)
    post login_path, params: { email: owner.email, password: "Secret123!" }
  end

  def lavorazione(titolo:, **date)
    ticket = create(:ticket, organization: org, project:, title: titolo)
    create(:agent_workflow, ticket:, **date)
  end

  # Una lavorazione in cui il sistema sta guardando la proposta e non ci riesce.
  def guasto_sul_candidato(titolo: "Non riesco a leggere", codice: "R502-GITHUB-001", quando: nil)
    workflow = lavorazione(titolo:, triage_requested_at: 3.hours.ago, triage_started_at: 2.hours.ago,
                           triaged_at: 2.hours.ago, planned_at: 90.minutes.ago, approved_at: 80.minutes.ago,
                           autopilot_started_at: 70.minutes.ago, autopilot_completed_at: 60.minutes.ago)
    create(:agent_delivery_candidate, workflow:, organization: org, state: :unreachable,
                                      last_error_code: codice, next_check_at: quando || riprova_alle)
    workflow
  end

  it "la riga dice cosa non riesce a leggere e a che ora riprova, con l'ora di quel record" do
    workflow = guasto_sul_candidato

    get member_home_approvals_path(view: Agents::Workflows::InFlight::VIEW)

    riga = Nokogiri::HTML(response.body).at_css(%([data-test="approvals-in-flight-retry-hint-#{workflow.id}"]))
    expect(riga).to be_present
    expect(riga.text).to include("R502-GITHUB-001")
    expect(riga.text).to include(I18n.l(riprova_alle, format: :short))
  end

  # La frase non deve comparire su una lavorazione che sta guardando e ci riesce, né su una che la
  # verifica l'ha già superata conservando il codice dell'errore di prima.
  it "non compare su chi sta guardando senza guai, né su chi ha già superato la verifica" do
    sana = lavorazione(titolo: "Controlli in corso", triage_requested_at: 3.hours.ago,
                       triage_started_at: 2.hours.ago, triaged_at: 2.hours.ago,
                       planned_at: 90.minutes.ago, approved_at: 80.minutes.ago,
                       autopilot_started_at: 70.minutes.ago, autopilot_completed_at: 60.minutes.ago)
    # Sta guardando e ci riesce: lo STATO è sano, ma il codice d'errore c'è lo stesso (resto di un
    # tentativo precedente). Se la riga guardasse solo il codice, questa parlerebbe di un guasto che
    # non c'è.
    create(:agent_delivery_candidate, workflow: sana, organization: org, state: :checks_running,
                                      last_error_code: "R502-GITHUB-001", next_check_at: riprova_alle)
    superata = lavorazione(titolo: "Verifica passata", triage_requested_at: 3.hours.ago,
                           triage_started_at: 2.hours.ago, triaged_at: 2.hours.ago,
                           planned_at: 90.minutes.ago, approved_at: 80.minutes.ago,
                           autopilot_started_at: 70.minutes.ago, autopilot_completed_at: 60.minutes.ago)
    create(:agent_delivery_candidate, :verified_passing, workflow: superata, organization: org,
                                      last_error_code: "R502-GITHUB-001", next_check_at: nil)
    # E una che il guasto ce l'ha nello stato, ma senza codice: non c'è niente da dire, e dire
    # «non riesco a leggere (nessun errore)» sarebbe una frase vuota.
    muta = lavorazione(titolo: "Senza codice", triage_requested_at: 3.hours.ago,
                       triage_started_at: 2.hours.ago, triaged_at: 2.hours.ago,
                       planned_at: 90.minutes.ago, approved_at: 80.minutes.ago,
                       autopilot_started_at: 70.minutes.ago, autopilot_completed_at: 60.minutes.ago)
    create(:agent_delivery_candidate, workflow: muta, organization: org, state: :unreachable,
                                      last_error_code: nil, next_check_at: riprova_alle)
    # E una il cui prossimo tentativo è già passato: l'ora da dire non c'è più, e stamparla
    # vorrebbe dire promettere un tentativo per un momento che è alle spalle.
    scaduta = lavorazione(titolo: "Tentativo passato", triage_requested_at: 3.hours.ago,
                          triage_started_at: 2.hours.ago, triaged_at: 2.hours.ago,
                          planned_at: 90.minutes.ago, approved_at: 80.minutes.ago,
                          autopilot_started_at: 70.minutes.ago, autopilot_completed_at: 60.minutes.ago)
    create(:agent_delivery_candidate, workflow: scaduta, organization: org, state: :unreachable,
                                      last_error_code: "R502-GITHUB-001", next_check_at: 10.minutes.ago)

    get member_home_approvals_path(view: Agents::Workflows::InFlight::VIEW)

    expect(response.body).not_to include("approvals-in-flight-retry-hint-#{sana.id}")
    expect(response.body).not_to include("approvals-in-flight-retry-hint-#{superata.id}")
    expect(response.body).not_to include("approvals-in-flight-retry-hint-#{muta.id}")
    expect(response.body).not_to include("approvals-in-flight-retry-hint-#{scaduta.id}")
  end

  # La riga resta contata fra quelle che vanno avanti da sole: il guasto non la fa diventare una cosa
  # che aspetta una persona, perché non aspetta nessuno — riprova da sola.
  it "resta contata fra quelle che vanno avanti da sole" do
    guasto_sul_candidato

    get member_home_approvals_path(view: Agents::Workflows::InFlight::VIEW)

    pagina = Nokogiri::HTML(response.body)
    stato = pagina.at_css("select[data-test='approvals-in-flight-filter-state']")
    expect(stato.at_css("option[value='running']").text).to include("1")
    # CYRA-630 — «aspetta una persona» non è più una voce di questo elenco: chi aspetta sta di là.
    expect(stato.at_css("option[value='waiting']")).to be_nil
  end

  # Il caso in cui la frase verrebbe presa dai rinvii dell'host invece che dal candidato: un ticket
  # che aspetta una persona e ha ANCHE un rinvio di coda «serve un chiarimento» non deve dire
  # «riprovo alle …», o chi guarda aspetta per sempre una cosa che non succede.
  it "non compare su chi aspetta una persona, nemmeno con un rinvio di coda attivo" do
    guasto = guasto_sul_candidato
    umana = lavorazione(titolo: "Aspetta te", triage_requested_at: 3.hours.ago,
                        triage_started_at: 2.hours.ago, triaged_at: 2.hours.ago, planned_at: 1.hour.ago)
    # E ha ANCHE una riga di candidato in guasto: senza, la frase non comparirebbe comunque e la
    # guardia sulle fasi che aspettano una persona non la eserciterebbe nessuno.
    create(:agent_delivery_candidate, workflow: umana, organization: org, state: :unreachable,
                                      last_error_code: "R502-GITHUB-001", next_check_at: riprova_alle)
    create(:agent_ticket_queue_deferral, organization_record: org, ticket: umana.ticket,
                                         host: create(:agent_host, organization: org),
                                         execution_phase: "planner", reason: "needs_clarification",
                                         retry_at: riprova_alle)

    get member_home_approvals_path(view: Agents::Workflows::InFlight::VIEW)

    expect(response.body).to include("approvals-in-flight-retry-hint-#{guasto.id}")
    expect(response.body).not_to include("approvals-in-flight-retry-hint-#{umana.id}")
  end

  # Una prova di rilascio andata male ha lasciato scritti il codice e il prossimo tentativo, ma la
  # lavorazione è ferma davvero: lì la frase giusta è quella che chiama una persona, non «riprovo
  # alle …».
  it "una prova di rilascio conclusa male chiama una persona, e non dice «riprovo alle»" do
    guasto = guasto_sul_candidato
    fallita = lavorazione(titolo: "Rilascio andato male", triage_requested_at: 3.hours.ago,
                          triage_started_at: 2.hours.ago, triaged_at: 2.hours.ago,
                          planned_at: 90.minutes.ago, approved_at: 80.minutes.ago,
                          autopilot_started_at: 70.minutes.ago, autopilot_completed_at: 65.minutes.ago,
                          candidate_verified_at: 60.minutes.ago, autopilot_approved_at: 55.minutes.ago,
                          closer_staging_started_at: 50.minutes.ago, closer_staging_completed_at: 45.minutes.ago,
                          closer_staging_verified_at: 40.minutes.ago, closer_production_approved_at: 35.minutes.ago,
                          closer_production_started_at: 30.minutes.ago,
                          closer_production_completed_at: 25.minutes.ago)
    fallita.probes.create!(kind: "deploy_smoke", bound_at: 20.minutes.ago, next_check_at: riprova_alle,
                           last_error_code: "release_run_failed",
                           expected: { "version" => "v0.30.0", "sha" => "a" * 40, "repo" => "x/y" })
    fallita.update!(blocked_at: Time.current, blocked_phase: "closer_production",
                    blocked_kind: "release_probe", blocked_reason: "release_probe: release_run_failed")

    get member_home_approvals_path(view: Agents::Workflows::InFlight::VIEW)

    expect(response.body).to include("approvals-in-flight-retry-hint-#{guasto.id}")
    expect(response.body).not_to include("approvals-in-flight-retry-hint-#{fallita.id}")
  end

  # Venticinque righe, venticinque ore diverse: se la pagina ne stampasse una sola vorrebbe dire che
  # la frase viene da un valore condiviso, e il costo non deve crescere col numero di righe.
  it "venticinque righe mostrano ognuna la propria ora, e non costano più di venticinque righe sane" do
    # A PARITÀ DI RIGHE: venticinque lavorazioni sane contro venticinque tutte in guasto. Confrontare
    # una riga con venticinque misurerebbe il costo di avere più righe, che questo lavoro non tocca.
    sane = nil
    allow_n_plus_one do
      sane = (1..25).map { |n| guasto_sul_candidato(titolo: "Sana #{n}", quando: 1.hour.ago) }
    end
    get member_home_approvals_path(view: Agents::Workflows::InFlight::VIEW)
    tutte_sane = captured_sql { get member_home_approvals_path(view: Agents::Workflows::InFlight::VIEW) }.size

    ore = (1..25).map { |n| (n * 3).minutes.from_now }
    allow_n_plus_one do
      sane.each_with_index do |workflow, n|
        workflow.delivery_candidates.sole.update!(next_check_at: ore[n])
      end
    end
    con_venticinque = captured_sql { get member_home_approvals_path(view: Agents::Workflows::InFlight::VIEW) }.size

    # Ogni riga mostra la SUA ora: se la pagina ne stampasse una sola vorrebbe dire che la frase
    # viene da un valore condiviso. Si contano le righe disegnate davvero — la pagina è impaginata —
    # e le ore distinte che portano: devono essere tante quante le righe.
    righe = Nokogiri::HTML(response.body).css('[data-test^="approvals-in-flight-retry-hint-"]')
    ore_mostrate = righe.map { |riga| riga.text[/\d{1,2}:\d{2}/] }
    expect(righe.size).to be >= 5
    expect(ore_mostrate.uniq.size).to eq(righe.size)
    expect(con_venticinque).to eq(tutte_sane)
  end
end
