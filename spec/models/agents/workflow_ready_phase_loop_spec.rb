# frozen_string_literal: true

require "rails_helper"

# CYAU-179 — LA PROVA, prima di togliere qualunque freno.
#
# Sulla macchina che esegue c'è un secondo tetto ai tentativi, con un numero diverso da quello del
# server e un conteggio tutto suo. Toglierlo è giusto — due freni vogliono dire due numeri e due posti
# dove leggerli, e con due macchine sullo stesso progetto il tetto reale raddoppia senza che nessuno
# l'abbia deciso — ma si può togliere SOLO se il server conta davvero ogni giro andato a vuoto.
#
# Il giro pericoloso è questo: una consegna viene ACCETTATA (quindi non è una bocciatura, e il
# contatore delle bocciature del server non si muove) e però non sposta il marcatore di conclusione
# della fase. Se la coda continua a proporre quella fase, il ticket riparte da capo, per sempre, e
# nessuno dei due conteggi lo vede. È già successo: trentuno tentativi e circa cinque dollari su un
# ticket solo.
#
# Questo spec è il gate di quel lavoro. Se è rosso, il freno della macchina NON si tocca.
RSpec.describe "la coda non ripropone all'infinito una fase consegnata" do
  # Le cinque fasi eseguibili, con: cosa deve essere vero perché la coda la proponga, e quale
  # marcatore la conclude. Una consegna accettata che NON muove quel marcatore è il caso in prova.
  FASI_E_MARCATORI = {
    "triage" => { pronta: { triage_requested_at: -> { 1.hour.ago } }, conclusa: :triaged_at },
    "planner" => { pronta: { triage_requested_at: -> { 2.hours.ago }, triage_started_at: -> { 2.hours.ago },
                             triaged_at: -> { 1.hour.ago } }, conclusa: :planned_at },
    "autopilot" => { pronta: { triage_requested_at: -> { 3.hours.ago }, triage_started_at: -> { 3.hours.ago },
                               triaged_at: -> { 2.hours.ago }, planned_at: -> { 2.hours.ago },
                               approved_at: -> { 1.hour.ago } }, conclusa: :autopilot_completed_at },
    "closer_staging" => { pronta: { triage_requested_at: -> { 4.hours.ago }, triage_started_at: -> { 4.hours.ago },
                                    triaged_at: -> { 3.hours.ago }, planned_at: -> { 3.hours.ago },
                                    approved_at: -> { 3.hours.ago }, autopilot_started_at: -> { 2.hours.ago },
                                    autopilot_completed_at: -> { 2.hours.ago },
                                    autopilot_approved_at: -> { 1.hour.ago } },
                          conclusa: :closer_staging_completed_at },
    "closer_production" => { pronta: { triage_requested_at: -> { 5.hours.ago }, triage_started_at: -> { 5.hours.ago },
                                       triaged_at: -> { 4.hours.ago }, planned_at: -> { 4.hours.ago },
                                       approved_at: -> { 4.hours.ago }, autopilot_started_at: -> { 3.hours.ago },
                                       autopilot_completed_at: -> { 3.hours.ago },
                                       autopilot_approved_at: -> { 3.hours.ago },
                                       closer_staging_started_at: -> { 2.hours.ago },
                                       closer_staging_completed_at: -> { 2.hours.ago }, closer_staging_verified_at: -> { 2.hours.ago },
                                       closer_production_approved_at: -> { 1.hour.ago } },
                             conclusa: :completed_at }
  }.freeze

  def lavorazione(fase)
    ticket = create(:ticket)
    attributi = FASI_E_MARCATORI.fetch(fase)[:pronta].transform_values(&:call)
    create(:agent_workflow, ticket:, ticket_snapshot_digest: "snapshot", **attributi)
  end

  FASI_E_MARCATORI.each_key do |fase|
    it "#{fase}: la coda la propone finché non è stata presa" do
      workflow = lavorazione(fase)

      expect(workflow.ready_execution_phase).to eq(fase)
    end

    # Il cuore: dopo che una macchina l'ha presa e ha consegnato SENZA concludere la fase, la coda
    # NON deve riproporla. Se la ripropone, il giro è infinito e nessuno lo conta.
    it "#{fase}: presa e consegnata senza concluderla, la coda non la ripropone" do
      # Il planner è l'unica fase senza un marcatore di avvio: `ready_execution_phase` la propone
      # finché `planned_at` è nullo, e una consegna accettata che non lo scrive (un piano dichiarato
      # non producibile) la fa riproporre all'infinito. Nessuno dei due conteggi lo vede: non è una
      # bocciatura, quindi il contatore del server non si muove.
      #
      # `pending` e non `skip`: il giorno in cui il buco viene chiuso questo esempio inizia a passare e
      # RSpec fa fallire la build chiedendo di togliere il pending. È il promemoria che il freno sulla
      # macchina può essere tolto — cioè il gate del resto di CYAU-179 — e non una riga da dimenticare.
      pending "il planner non ha un marcatore di avvio: finché non ce l'ha, il freno sulla macchina resta" if fase == "planner"

      workflow = lavorazione(fase)
      colonne = Agents::Workflow::PHASE_START_COLUMNS[fase]

      # «Presa da una macchina»: è ciò che il claim scrive. Il planner non ha un avvio dedicato, ed è
      # esattamente il buco che questo spec deve mostrare invece di aggirare.
      workflow.update!(colonne[:started] => Time.current) if colonne

      expect(workflow.reload.public_send(FASI_E_MARCATORI.fetch(fase)[:conclusa])).to be_nil,
                                                                          "lo scenario ha già concluso la fase"
      expect(workflow.ready_execution_phase).not_to eq(fase),
                                                    "la coda ripropone #{fase} dopo una consegna che non l'ha conclusa: giro infinito"
    end
  end
end
