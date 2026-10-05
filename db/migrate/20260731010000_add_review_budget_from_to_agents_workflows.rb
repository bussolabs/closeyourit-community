# frozen_string_literal: true

# Da quando contare le bocciature di una fase (CYRA-218, rilievo di review).
#
# Il tetto contava TUTTA la storia della fase. Ma gli attempt bocciati sono audit immutabile e non
# spariscono quando una persona dice "riprova": al primo nuovo tentativo bocciato il conteggio era già
# oltre il tetto e il blocco tornava subito. In pratica "Riprova" concedeva UN colpo invece dei due
# dichiarati, e il pulsante si spegneva da solo dopo un giro.
#
# Chi sblocca (riprova esplicita, approvazione del piano, richiesta di modifiche) timbra qui il momento;
# il conteggio guarda solo i tentativi successivi. NULL = conta tutta la storia, che è il comportamento
# giusto per i workflow già esistenti: non hanno mai avuto uno sblocco da cui ripartire.
class AddReviewBudgetFromToAgentsWorkflows < ActiveRecord::Migration[8.1]
  def change
    add_column :agents_workflows, :review_budget_from, :datetime
  end
end
