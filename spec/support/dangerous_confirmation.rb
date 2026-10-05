# frozen_string_literal: true

# CYRA-728 — le azioni che il catalogo segna pericolose non partono senza una conferma esplicita.
# Dal browser, un'azione che arriva senza il gesto si ferma sulla pagina di conferma, che rifà la
# stessa richiesta con la conferma dentro. I system spec che esercitano quelle azioni passano di lì:
# questo helper preme il bottone, così ogni prova racconta il flusso vero invece di saltarlo.
module DangerousConfirmationSupport
  def conferma_azione_pericolosa
    expect(page).to have_css("[data-test='dangerous-action-confirmation']")
    find("[data-test='dangerous-action-confirm']").click
  end
end

RSpec.configure do |config|
  config.include DangerousConfirmationSupport, type: :system
end
