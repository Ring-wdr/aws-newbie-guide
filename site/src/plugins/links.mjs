// 상대 링크 재작성: 다른 원고(.md) → 사이트 경로, lab·sdk 등 그 밖의 파일 → 소스 보기 페이지.
import { visit } from 'unist-util-visit';
import { resolveLink } from '../lib/links.mjs';

export function transformLinks(tree, ctx) {
  const { rep, rel } = ctx;
  rep.touch('links');
  ctx.linkedFiles = new Set();
  visit(tree, (node) => {
    if (node.type !== 'link' && node.type !== 'definition') return;
    const r = resolveLink(rel, node.url);
    rep.note('links', r.kind);
    switch (r.kind) {
      case 'external':
      case 'anchor':
        return;
      case 'page':
      case 'file':
      case 'dir':
      case 'unbuilt':
        rep.handled('links');
        if (r.kind === 'file' || r.kind === 'dir') ctx.linkedFiles.add(r.target);
        node.url = r.href;
        return;
      case 'outside':
        rep.unrecognised('links', `저장소 밖을 가리키는 링크: ${node.url}`, node);
        return;
      default:
        rep.unrecognised('links', `대상이 없는 링크: ${node.url}`, node);
    }
  });
  // 원고 안의 HTML <a href="...">는 드물다. 있으면 셈만 하고 보고한다.
  visit(tree, 'html', (node) => {
    if (/<a\s[^>]*href=/i.test(node.value)) rep.unrecognised('links', 'HTML <a href> 링크(재작성하지 않음)', node);
  });
}
