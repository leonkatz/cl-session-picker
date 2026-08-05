func hasLatest(_ w) -> Bool {
  return w.latestAt != nil
}

func ageMins(_ w, _ nowEpoch) -> Int {
  return (nowEpoch - w.latestAt) / 60
}

func agoLabel(_ mins) -> String {
  if mins < 1 { return "now" }
  if mins < 60 { return "\(mins)m" }
  if mins < 1440 { return "\(mins / 60)h \(mins % 60)m" }
  return "\(mins / 1440)d \((mins % 1440) / 60)h"
}

func lastMsg(_ w) -> String {
  if w.latestMessage != nil && w.latestMessage != "" { return w.latestMessage }
  return ""
}

// A session that answered very recently is effectively "hot": either still
// working or just handed you something to read.
func laneOf(_ w, _ nowEpoch) -> String {
  // "hasLatest(w) == false" instead of "!hasLatest(w)": the sidebar
  // interpreter silently skips the prefix-! on a user func call, which
  // dumped every cold session into the idle lane.
  if hasLatest(w) == false { return "cold" }
  let m = ageMins(w, nowEpoch)
  if m < 10 { return "active" }
  if m < 120 { return "recent" }
  return "idle"
}

func laneHeader(_ icon, _ name, _ count, _ tint) -> some View {
  HStack(spacing: 6) {
    Image(systemName: icon).font(.system(size: 11)).foregroundColor(tint)
    Text(name).font(.system(size: 11)).fontWeight(.semibold).textCase(.uppercase).foregroundColor(tint)
    Text("\(count)").font(.system(size: 10, design: .monospaced)).foregroundColor(tint)
      .padding(3)
      .background { Capsule().foregroundColor(tint).opacity(0.18) }
    Spacer()
  }
  .padding(4)
}

func row(_ w, _ tint, _ nowEpoch) -> some View {
  Button(action: { cmux("workspace.select", workspace_id: w.id) }) {
    HStack(alignment: .top, spacing: 7) {
      Capsule().frame(width: 3, height: 30)
        .foregroundColor(w.selected ? tint : Color(red: 0.5, green: 0.5, blue: 0.5))
        .opacity(w.selected ? 1.0 : 0.25)
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 5) {
          Text(w.title)
            .font(.system(size: 12))
            .fontWeight(w.selected ? .semibold : .regular)
            .lineLimit(1).truncationMode(.tail)
          Spacer()
          if hasLatest(w) {
            Text(agoLabel(ageMins(w, nowEpoch)))
              .font(.system(size: 9, design: .monospaced))
              .foregroundColor(.tertiary)
          }
        }
        if lastMsg(w) != "" {
          Text(lastMsg(w))
            .font(.system(size: 9))
            .foregroundColor(.secondary)
            .lineLimit(2)
            .truncationMode(.tail)
        }
      }
      if w.unread > 0 {
        Text("\(w.unread)")
          .font(.system(size: 9, design: .monospaced)).bold()
          .foregroundColor("#1A1A22")
          .padding(4)
          .background { Circle().foregroundColor("#E0AF68") }
      }
    }
    .padding(4)
    .background {
      RoundedRectangle(cornerRadius: 6)
        .foregroundColor(w.selected ? tint : "#000000")
        .opacity(w.selected ? 0.14 : 0.0)
    }
  }
}

// Cold sessions get one compact tappable line each - no message body to show.
func coldRow(_ w) -> some View {
  Button(action: { cmux("workspace.select", workspace_id: w.id) }) {
    HStack(spacing: 6) {
      Image(systemName: "zzz").font(.system(size: 9)).foregroundColor(.tertiary)
      Text(w.title).font(.system(size: 11)).foregroundColor(.secondary)
        .lineLimit(1).truncationMode(.tail)
      Spacer()
    }
    .padding(3)
  }
}

VStack(alignment: .leading, spacing: 6) {
  HStack {
    Text("Sessions").font(.system(size: 13)).bold()
    Spacer()
    Text(clock.time).font(.system(size: 10, design: .monospaced)).foregroundColor(.tertiary)
  }
  .padding(4)
  Divider()

  let ws = workspaces.prefix(40)
  let active = ws.filter { laneOf($0, clock.epoch) == "active" }.sorted { $0.latestAt > $1.latestAt }
  let recent = ws.filter { laneOf($0, clock.epoch) == "recent" }.sorted { $0.latestAt > $1.latestAt }
  let idle = ws.filter { laneOf($0, clock.epoch) == "idle" }.sorted { $0.latestAt > $1.latestAt }
  let cold = ws.filter { laneOf($0, clock.epoch) == "cold" }

  laneHeader("bolt.fill", "Active", active.count, "#7AA2F7")
  if active.count == 0 {
    Text("none").font(.system(size: 10)).foregroundColor(.tertiary).padding(4)
  }
  ForEach(active) { w in row(w, "#7AA2F7", clock.epoch) }

  Divider()
  laneHeader("clock.fill", "Recent (< 2h)", recent.count, "#E0AF68")
  if recent.count == 0 {
    Text("none").font(.system(size: 10)).foregroundColor(.tertiary).padding(4)
  }
  ForEach(recent) { w in row(w, "#E0AF68", clock.epoch) }

  Divider()
  laneHeader("moon.zzz.fill", "Idle", idle.count, "#9ECE6A")
  ForEach(idle) { w in row(w, "#9ECE6A", clock.epoch) }

  if cold.count > 0 {
    Divider()
    laneHeader("snowflake", "Cold (no activity)", cold.count, "#565F89")
    ForEach(cold) { w in coldRow(w) }
  }
  Spacer()
}
