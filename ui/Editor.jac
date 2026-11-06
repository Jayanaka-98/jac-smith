"""Unlocked editing: CodeMirror (bundled, works offline) with ⌘S to save and selection reporting."""
import from "react" { useEffect, useMemo }
import from "@uiw/react-codemirror" { useCodeMirror, EditorView, keymap }
import from "@codemirror/lang-python" { python }
import from "@codemirror/lang-javascript" { javascript }

def:pub CodeEditor(
    text: str,
    lang: str,
    jumpLine: int,
    onChange: Callable[[str], None],
    onSave: Callable[[], None],
    onSelection: Callable[[int, int, str], None]
) -> JsxElement {
    has hostRef: Ref[HTMLDivElement] = Ref();
    has cbs: Ref[any] = Ref(None);

    # the extensions are built once; they reach the latest callbacks through this ref
    cbs.current = {"change": onChange, "save": onSave, "select": onSelection};

    exts = useMemo(lambda {
        lang_ext = javascript({"typescript": True, "jsx": True}) if lang in ["javascript", "typescript", "js"] else python();
        save_keys = keymap.of([{
            "key": "Mod-s", "preventDefault": True,
            "run": lambda (v: any) -> bool { cbs.current["save"].call(None); return True; }
        }]);
        on_update = EditorView.updateListener.of(lambda (u: any) {
            if u.selectionSet {
                sel = u.state.selection.main;
                if sel["from"] != sel["to"] {
                    a = u.state.doc.lineAt(sel["from"]).number;
                    b = u.state.doc.lineAt(sel["to"]).number;
                    cbs.current["select"].call(None, a, b, u.state.sliceDoc(sel["from"], sel["to"]));
                }
            }
        });
        return [lang_ext, save_keys, on_update];
    }, [lang]);

    cm = useCodeMirror({
        "value": text,
        "extensions": exts,
        "theme": "light" if document.documentElement.getAttribute("data-theme") == "daylight" else "dark",
        "height": "100%",
        "autoFocus": True,
        "basicSetup": {"foldGutter": True, "highlightActiveLine": True, "bracketMatching": True, "autocompletion": False},
        "onChange": lambda (v: str) { cbs.current["change"].call(None, v); }
    });

    useEffect(lambda {
        if hostRef.current {
            cm.setContainer(hostRef.current);
        }
        return lambda { };
    }, [hostRef.current]);

    useEffect(lambda {
        if cm.view and jumpLine > 0 {
            n = min(jumpLine, cm.view.state.doc.lines);
            line = cm.view.state.doc.line(n);
            cm.view.dispatch({"selection": {"anchor": line["from"]}, "effects": EditorView.scrollIntoView(line["from"], {"y": "center"})});
        }
        return lambda { };
    }, [cm.view, jumpLine]);

    <div className="cm-host" ref={hostRef} />
}
