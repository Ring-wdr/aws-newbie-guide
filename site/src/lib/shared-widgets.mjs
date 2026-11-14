// 공용 위젯: 모듈 폴더(src/widgets/mNN/) 대신 공용부(src/progress/ 등)에 하나만 두고, 어느 모듈 원고에서나
// 같은 표시 줄로 부른다. 모듈 폴더에 같은 이름의 위젯이 있으면 그쪽이 먼저다(markers.mjs, MarkdownContent.astro).
// 이 목록과 그 구현은 환경 구축 담당이 관리한다(UI 저자의 위젯 폴더 밖).
export const SHARED_WIDGETS = ['progress-tracker'];
