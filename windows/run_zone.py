from zone.__main__ import main

if __name__ == "__main__":
    import sys
    if len(sys.argv) > 1 and sys.argv[1] == "--self-test":
        try:
            from zone.qualification import main as qualify
            code = qualify(sys.argv[2:])
        except Exception:
            from pathlib import Path
            import traceback
            if "--output" in sys.argv:
                output = Path(sys.argv[sys.argv.index("--output")+1])
                output.mkdir(parents=True, exist_ok=True)
                (output/"self-test-error.txt").write_text(traceback.format_exc(), encoding="utf-8")
            code = 1
        raise SystemExit(code)
    raise SystemExit(main())
