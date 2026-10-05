# frozen_string_literal: true

module Member
  # Il punto d'ingresso unico per annotare qualcosa (CYRA-357). Il prodotto offre quattro posti dove
  # scrivere una cosa da fare — ticket, idea, todo, azione di lavoro — e nessuna pagina diceva quando
  # si sceglie l'uno invece dell'altro: chi si fermava a chiederselo finiva per non scrivere niente
  # (0 azioni, 0 todo, 42 idee ferme contro 1163 ticket).
  #
  # È una pagina, non un dialogo: si condivide con un link, funziona senza JS e si torna indietro col
  # tasto del browser. Non crea niente — instrada ai form che esistono già, che restano raggiungibili
  # anche direttamente dalle rispettive sezioni (chi sa dove andare non paga il passo in più).
  class QuickAddController < Member::BaseController
    permission_not_required "Pagina che spiega dove annotare una cosa: non crea niente, rimanda ai form che hanno " \
                            "già il proprio gate."

    def show; end
  end
end
