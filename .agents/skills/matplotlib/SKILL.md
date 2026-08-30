---
name: matplotlib
description: 'This skill should be used when the user invokes "/matplotlib" to plot data from the current context using matplotlib (via uv) and output the resulting image path.'
tools: Bash
disable-model-invocation: true
---

# Plot data with matplotlib

Plot data from the most recent interaction context using matplotlib. Generate a PNG image with a transparent background and output it as a markdown image so it renders inline.

## How to plot

1. Extract or derive plottable data from the current context.
2. If the Emacs foreground color is not already known from a previous plot in this session, query it:
   ```sh
   emacsclient --eval '
   (face-foreground (quote default))'
   ```
   This returns a hex color like `"#eeffff"`. Reuse it for all subsequent plots.
3. Write a Python script to a temporary file using that color.
4. Run the script with `uv run --with matplotlib`.
5. Output the result as a markdown image on its own line:
   ```
   ![description](/tmp/agent-plot-XXXX.png)
   ```

```sh
uv run --with matplotlib /tmp/agent-plot-XXXX.py
```

## Python script template

```python
import matplotlib.pyplot as plt

fig, ax = plt.subplots(figsize=(10, 6))
fig.patch.set_alpha(0)
ax.set_facecolor('none')

FG = "#eeffff"  # from emacsclient query
ax.spines['bottom'].set_color(FG)
ax.spines['left'].set_color(FG)
ax.spines['top'].set_visible(False)
ax.spines['right'].set_visible(False)
ax.tick_params(colors=FG)
ax.xaxis.label.set_color(FG)
ax.yaxis.label.set_color(FG)
ax.title.set_color(FG)

# ... plot commands using the data ...

plt.tight_layout()
plt.savefig("/tmp/agent-plot-XXXX.png", dpi=150, transparent=True)
```

## Rules

- Query the Emacs foreground color once per session and reuse it for all subsequent plots. Only query again if the color is not already known.
- Always use `fig.patch.set_alpha(0)` and `ax.set_facecolor('none')` for transparent background.
- Always use `transparent=True` in `savefig`.
- Always use a timestamp in the filename (e.g., `/tmp/agent-plot-$(date +%s).png`). Never use descriptive names like `agent-plot-lorenz.png`.
- Always run scripts with `uv run --with matplotlib`. Do not use `pip install`.
- After the script runs successfully, output a markdown image (`![description](path)`) on its own line.
- Choose an appropriate plot type for the data (line, bar, scatter, histogram, pie, heatmap, etc.).
- Include a title, axis labels, and a legend when they add clarity.
- Style the legend to match the theme: `ax.legend(facecolor='#1a1a2e', edgecolor=FG, labelcolor=FG)` for dark backgrounds.
- Use `ax.grid(True, alpha=0.2, color=FG)` for subtle gridlines.
- Hide top and right spines for a cleaner look.
- If no plottable data exists in the recent context, inform the user.
