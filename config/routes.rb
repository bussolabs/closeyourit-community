Rails.application.routes.draw do
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html
  #
  # Un file per canale, sotto `config/routes/`: si apre quello dell'area su cui si sta lavorando
  # invece di scorrere millecinquecento righe in cui stanno tutti insieme.
  #
  # L'ORDINE DI QUESTO ELENCO È L'ORDINE DELLE ROTTE. Rails serve la prima che combacia, quindi
  # spostare una riga qui cambia chi risponde senza toccare una sola rotta: l'apex deve precedere la
  # root del sito, il catch-all dell'area utenti deve venire dopo tutte le sue rotte vere, le pagine
  # di errore restano in fondo. `spec/config/routes_layout_spec.rb` presidia queste precedenze.
  draw(:service)
  draw(:webhooks)
  draw(:ai_gateway)
  draw(:api)
  draw(:cli)
  draw(:account)
  draw(:valhalla)
  draw(:member)
  draw(:website)
  draw(:errors)
end
