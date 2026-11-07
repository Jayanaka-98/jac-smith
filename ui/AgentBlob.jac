"""The minimized agent: a small floating orb on the right. It spins while the agent works and
shows a dot when a reply arrives while you are away. Click it to bring the panel back."""
import from "lucide-react" { Sparkles }

def:pub AgentBlob(focusName: str, busy: bool, unread: bool, onOpen: Callable[[], None]) -> JsxElement {
    tip = "Agent · " + focusName + (" · working..." if busy else (" · new reply" if unread else ""));
    <button className={"agent-blob" + (" busy" if busy else "") + (" unread" if unread else "")} onClick={lambda (e: MouseEvent) { onOpen(); }} title={tip}>
        <span className="blob-ring" />
        <span className="blob-core"><Sparkles size={20} /></span>
        {unread and <span className="blob-dot" />}
        <span className="blob-label">{"Working on " + focusName if busy else "Agent"}</span>
    </button>
}
