/// A little "i" icon with a hover/focus tooltip, used next to labels that
/// would otherwise be cryptic.
export default function Tip(props: { text: string; down?: boolean }) {
  return (
    <span
      class={`tip${props.down ? " tip-down" : ""}`}
      tabindex={0}
      aria-label={props.text}
    >
      <svg class="tip-icon" viewBox="0 0 16 16" aria-hidden="true">
        <circle cx="8" cy="8" r="7" />
        <circle class="tip-dot" cx="8" cy="4.6" r="1" />
        <rect class="tip-stem" x="7.1" y="6.9" width="1.8" height="4.7" rx="0.9" />
      </svg>
      <span class="tip-bubble">{props.text}</span>
    </span>
  );
}
