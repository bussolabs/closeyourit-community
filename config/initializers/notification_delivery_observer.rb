# frozen_string_literal: true

# CYRA-672 — chi segna una notifica come consegnata e' questo osservatore, non chi la accoda.
#
# `to_prepare` e non un initializer semplice perche' la classe vive in app/ e in sviluppo viene
# ricaricata. Il ricaricamento puo' lasciare registrato anche l'oggetto classe precedente: l'effetto
# e' al piu' una seconda `update_all` identica sulle stesse righe, quindi innocuo.
Rails.application.config.to_prepare do
  ActionMailer::Base.register_observer(Notifications::DeliveryObserver)
end
