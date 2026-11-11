// Local wall-clock time keeps the scene in sync after sleep and timezone changes.
// Art-directed hours, not astronomical sunrise/sunset or geolocation.
export function daylightAt(date = new Date()) {
  const hour = date.getHours() + date.getMinutes() / 60 + date.getSeconds() / 3600
  const stops = [[0, 0, 0], [5, 0, 0], [6.5, 0.35, 1], [8, 1, 0], [16, 1, 0], [18.5, 0.35, 1], [20, 0, 0], [24, 0, 0]]
  const index = stops.findIndex(stop => stop[0] > hour)
  const [start, daylight, warmth] = stops[index - 1], [end, nextDaylight, nextWarmth] = stops[index]
  const progress = (hour - start) / (end - start)
  const blend = progress * progress * (3 - 2 * progress)
  return { daylight: daylight + (nextDaylight - daylight) * blend, warmth: warmth + (nextWarmth - warmth) * blend }
}
