"""Role palette and small formatting helpers shared by the views."""

glob ROLE_ORDER: list[str] = [
    "ENTRY", "UI", "API", "DOMAIN", "AI", "DATA", "INTEGRATION", "INFRA", "CONFIG", "TOOLING", "TEST"
];

glob ROLE_RGB: dict[str, str] = {
    "ENTRY": "245,184,74",
    "UI": "236,110,173",
    "API": "92,154,255",
    "DOMAIN": "160,124,255",
    "AI": "64,212,226",
    "DATA": "62,207,142",
    "INTEGRATION": "232,200,80",
    "INFRA": "126,141,163",
    "CONFIG": "170,170,170",
    "TOOLING": "150,138,124",
    "TEST": "150,200,90"
};

glob ECO_LABEL: dict[str, str] = {
    "project": "in project",
    "pypi": "PyPI",
    "npm": "npm",
    "jac": "Jac",
    "stdlib": "Python stdlib",
    "node": "Node built-in"
};

def:pub role_rgb(role: str) -> str {
    if role in ROLE_RGB {
        return ROLE_RGB[role];
    }
    return "110,120,135";
}

def:pub role_color(role: str) -> str {
    return "rgb(" + role_rgb(role) + ")";
}

def:pub role_tint(role: str, alpha: float) -> str {
    return "rgba(" + role_rgb(role) + "," + str(alpha) + ")";
}

def:pub eco_label(eco: str) -> str {
    if eco in ECO_LABEL {
        return ECO_LABEL[eco];
    }
    return eco;
}

def:pub fmt_count(n: int) -> str {
    if n >= 1000 {
        return str(round(n / 1000.0, 1)) + "k";
    }
    return str(n);
}

def:pub pct(x: float) -> str {
    return str(round(x * 100.0, 3)) + "%";
}
