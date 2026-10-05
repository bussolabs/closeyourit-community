// Configure your import map in config/importmap.rb. Read more: https://github.com/rails/importmap-rails
import "@hotwired/turbo-rails"
// CYRA-827 — un riquadro che riceve la login o una pagina d'errore va aperto a schermo intero,
// invece di essere svuotato con «Content missing» (che porta via anche il ripiego che aveva dentro).
import "frame_missing"
import "controllers"
