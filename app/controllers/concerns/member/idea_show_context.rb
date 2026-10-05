# frozen_string_literal: true

module Member
  # Dati della pagina di un'idea, condivisi dalla show e da chi deve RIMOSTRARLA dopo un commento
  # rifiutato (CYRA-371).
  #
  # Prima il testo rifiutato tornava all'utente dentro `flash[:comment_draft]`, cioè dentro il cookie
  # di sessione: con il tetto a 240 caratteri ci stava sempre, con il tetto largo delle idee no — un
  # intervento di poche migliaia di caratteri sfonda i 4 KB del cookie e la risposta diventa un errore
  # del server (`ActionDispatch::Cookies::CookieOverflow`). E si sarebbe rotto anche a testo VALIDO,
  # perché il draft si conserva per qualunque motivo di rifiuto (idea nel frattempo congelata).
  #
  # Il testo lungo non viaggia più: la pagina si rende sul posto, col contenuto già nel campo.
  # Il controller che lo include resta padrone del proprio scoping (anti-BOLA su `@idea`).
  module IdeaShowContext
    private

    def load_idea_show_context
      @voted = @idea.votes.exists?(account_id: Current.account.id)
      # CYRA-360 — chi ha votato, per nome: il voto dice quante persone vogliono l'idea, e un
      # numero da solo non basta a farci una discussione. Ordine per nome, non per momento del
      # voto: è un elenco da leggere, non una classifica.
      @voters = @idea.voters.order(:name).to_a
      @comments = @idea.comments.includes(:author).to_a
      @cases = @idea.cases.to_a
      # CYRA-845 — collegamenti: base, evoluzioni, parenti alla pari; e le idee ancora collegabili
      # (stesso progetto, non già legate, non sé stessa) per il selettore «Collega un'idea».
      @parent = @idea.parent
      @evolutions = @idea.evolutions.to_a
      @related = @idea.related_ideas
      linked_ids = [ @idea.id, @parent&.id, *@evolutions.map(&:id), *@related.map(&:id) ].compact
      @linkable_ideas = @idea.project.ideas.where.not(id: linked_ids).order(:title).to_a
      @can_edit = manageable_idea?("ideas.edit")
      @can_delete = manageable_idea?("ideas.delete")
      @can_convert = manageable_idea?("ideas.convert")
      @can_moderate_comments = can?("ideas.comment.delete_any", scope: @idea.project)
      # Activity-log generalizzato: blocco Audit (ultimo evento) + cronologia nel modale.
      @activity_events = @idea.activity_events.chronological.includes(:actor, :true_actor).to_a
      @last_activity = @activity_events.last
    end

    # L'autore gestisce sempre la propria idea aperta; sulle idee altrui serve la chiave dedicata.
    def manageable_idea?(key)
      @idea.authored_by?(Current.account) || can?(key, scope: @idea.project)
    end
  end
end
