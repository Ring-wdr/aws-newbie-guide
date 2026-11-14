// 변환기 공용 도우미: 보고서 기록, HTML 이스케이프, mdast 노드 만들기.

/** 변환기별 보고서. file.data.guideReport[변환기] = {handled, unrecognised:[{what, line}], notes:{...}} */
export function reporter(file) {
  file.data.guideReport ??= {};
  const rep = file.data.guideReport;
  const get = (name) => (rep[name] ??= { handled: 0, unrecognised: [], notes: {} });
  return {
    handled(name, n = 1) {
      get(name).handled += n;
    },
    note(name, key, n = 1) {
      const r = get(name);
      r.notes[key] = (r.notes[key] || 0) + n;
    },
    unrecognised(name, what, node) {
      get(name).unrecognised.push({ what, line: node?.position?.start?.line ?? null });
    },
    touch(name) {
      get(name);
    },
  };
}

export function esc(s) {
  return String(s)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

/** hName을 가진 컨테이너 노드. remark-rehype가 그대로 요소로 바꾼다(자식도 변환). */
export function box(tag, props, children) {
  return { type: 'guideBox', data: { hName: tag, hProperties: props }, children };
}

export function html(value) {
  return { type: 'html', value };
}

export const isComment = (node) => node?.type === 'html' && /^<!--[\s\S]*-->\s*$/.test(node.value.trim());

/** 노드 목록을 가진 모든 부모(루트·목록 항목·인용 등)를 차례로 돈다. */
export function eachParent(tree, fn) {
  const walk = (node) => {
    if (!node || !Array.isArray(node.children)) return;
    fn(node);
    for (const c of node.children) walk(c);
  };
  walk(tree);
}
