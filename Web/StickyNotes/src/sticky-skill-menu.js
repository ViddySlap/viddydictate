// JS owns the right-click menu chrome; Swift owns which Sticky Skills exist. The only accepted catalog
// shape is [{id, displayName}]. Everything else on a payload row is ignored by construction.
export function renderStickySkillMenu(payload, { section, separator, items }) {
  const rows = Array.isArray(payload?.items) ? payload.items : [];
  const seen = new Set();
  const catalog = [];
  for (const row of rows) {
    const id = typeof row?.id === "string" ? row.id.trim() : "";
    const displayName = typeof row?.displayName === "string" ? row.displayName.trim() : "";
    if (!id || !displayName || seen.has(id)) continue;
    seen.add(id);
    catalog.push({ id, displayName });
  }

  items.replaceChildren();
  const visible = catalog.length > 0;
  section.hidden = !visible;
  separator.hidden = !visible;
  if (!visible) return;

  for (const skill of catalog) {
    const button = items.ownerDocument.createElement("button");
    button.type = "button";
    button.dataset.action = "stickySkill";
    button.dataset.skillId = skill.id;
    button.textContent = skill.displayName;
    button.title = skill.displayName;
    items.appendChild(button);
  }
}
