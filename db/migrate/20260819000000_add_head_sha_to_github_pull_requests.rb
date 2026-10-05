# frozen_string_literal: true

# Quale codice c'è dentro una proposta di modifica, e quando GitHub ce l'ha detto (CYRA-600).
#
# Finora di una proposta si conservava il NOME del ramo, che è un'etichetta mobile: chi spinge un
# commit sposta il ramo e il nome resta identico. Chi guardava non aveva modo di accorgersi che il
# codice fosse cambiato dopo essere stato visto.
#
# `head_sha` è una CACHE, non una prova: dice l'ultimo codice che GitHub ci ha comunicato, e vale
# quanto l'ultima consegna arrivata. La prova di «questo è il codice che hai approvato» sta altrove
# — sul candidato congelato — e non va confusa con questa colonna.
#
# `github_updated_at` è l'orologio della CONSEGNA di GitHub, e serve per una ragione precisa: gli
# webhook arrivano at-least-once e fuori ordine. Senza un orologio, una consegna vecchia
# sovrascriverebbe una nuova e il codice annotato tornerebbe indietro. Non si può usare la colonna
# `updated_at` della riga: quella è l'ora in cui abbiamo salvato noi, non l'ora in cui è successo.
class AddHeadShaToGithubPullRequests < ActiveRecord::Migration[8.1]
  def change
    add_column :github_pull_requests, :head_sha, :string,
               comment: "Ultimo SHA noto della testa della proposta: cache dell'ultima consegna GitHub, mai una prova."
    add_column :github_pull_requests, :github_updated_at, :datetime,
               comment: "Orologio della consegna GitHub, per scartare gli webhook fuori ordine. Non è updated_at."
  end
end
