// Clones an icon the layout drew in <template id="ui-icons"> with Ui::IconComponent, so no
// controller builds SVG by hand. Add a name to app/views/shared/_icon_templates.html.erb first. CYRA-926
export function icon(name, className = "") {
  const source = document.getElementById("ui-icons")?.content.querySelector(`[data-icon="${name}"]`)
  if (!source) throw new Error(`Icon "${name}" is not in shared/_icon_templates`)

  const svg = source.cloneNode(true)
  if (className) svg.setAttribute("class", `${svg.getAttribute("class")} ${className}`)
  return svg
}
