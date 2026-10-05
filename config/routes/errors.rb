# Pagine di errore dell'applicazione (config.exceptions_app). Ultime: non devono precedere nulla.

# CYRA-372 — pagine di errore dell'applicazione (config.exceptions_app): in italiano, col menu
# quando la sessione c'è, e sempre con una via d'uscita. `via: :all` perché ci si arriva con
# qualunque verbo, non solo GET.
match "/404", to: "errors#not_found", via: :all
match "/422", to: "errors#unprocessable_entity", via: :all
match "/500", to: "errors#internal_server_error", via: :all
