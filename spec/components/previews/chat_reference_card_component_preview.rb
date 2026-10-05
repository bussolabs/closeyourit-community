# frozen_string_literal: true

# Preview del riferimento polimorfico taggato in chat (feature distintiva): 6 tipi taggabili +
# stato "non più visibile" (revoca RBAC live). Il componente legge SOLO attributi/associazioni già
# risolte (code/key/title/status) e costruisce l'href via routes.url_helpers usando `to_param` —
# build_stubbed basta (nessuna riga scritta nel DB dev ad ogni view di /lookbook) per
# project/ticket/error/metric/log: l'id fittizio di build_stubbed è sufficiente per `to_param`, e
# le associazioni referenziate dal ticket (project/status/priority/reporter) sono passate come
# override espliciti per bypassare i `create` incorporati nella factory :ticket (che altrimenti
# scatterebbero comunque, anche con l'oggetto ticket stesso build_stubbed — vedi commento su
# #sample_ticket). Eccezione: `uptime` resta `create` — la factory :uptime_monitor ha un
# `after(:build)` che verifica `project.platforms.uptime_capable.exists?` e, in assenza, chiama
# `project.project_platforms.create!`: con un project stubbato (mai persistito) quella create!
# violerebbe la FK (project_id inesistente) — serve un project REALMENTE persistito.
class ChatReferenceCardComponentPreview < ViewComponent::Preview
  def project
    render(ChatReferenceCardComponent.new(referable: sample_project))
  end

  def ticket
    render(ChatReferenceCardComponent.new(referable: sample_ticket))
  end

  def error
    render(ChatReferenceCardComponent.new(referable: FactoryBot.build_stubbed(:error_group, project: sample_project)))
  end

  def metric
    render(ChatReferenceCardComponent.new(referable: FactoryBot.build_stubbed(:metric_group, project: sample_project)))
  end

  def log
    render(ChatReferenceCardComponent.new(referable: FactoryBot.build_stubbed(:log_entry, project: sample_project)))
  end

  # Non build_stubbed: vedi eccezione nel commento di testa al file (FK verificata a build-time
  # dalla factory). Progetto proprio (non sample_project) — la factory ne crea uno persistito.
  def uptime
    render(ChatReferenceCardComponent.new(referable: FactoryBot.create(:uptime_monitor)))
  end

  # Revoca live d'accesso (es. rimosso dal progetto del ticket taggato): niente label/stato/link,
  # solo placeholder neutro.
  def unavailable
    render(ChatReferenceCardComponent.new(referable: sample_ticket, visible: false))
  end

  private

  def sample_project
    @sample_project ||= FactoryBot.build_stubbed(:project, key: "DEMO")
  end

  # status/priority/reporter passati espliciti: la factory :ticket li definisce con `create(...)`
  # incorporato (non `association`), quindi scattano SEMPRE a meno di override esplicito, anche
  # quando il ticket stesso è build_stubbed. `with_default_body: false` salta l'after(:build) che
  # altrimenti costruirebbe uno scenario BDD — non necessario: il componente legge solo code/status.
  def sample_ticket
    @sample_ticket ||= FactoryBot.build_stubbed(
      :ticket,
      project: sample_project,
      status: FactoryBot.build_stubbed(:ticket_status, organization: sample_project.organization),
      priority: FactoryBot.build_stubbed(:ticket_priority, organization: sample_project.organization),
      reporter: FactoryBot.build_stubbed(:account),
      number: 1,
      with_default_body: false
    )
  end
end
