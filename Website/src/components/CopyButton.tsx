import { useEffect, useRef, useState } from "react";
import { Icon } from "./Icon";

interface CopyButtonProps {
  text: string;
  className?: string;
  label?: string;
}

async function copyText(text: string) {
  try {
    await navigator.clipboard.writeText(text);
    return true;
  } catch {
    try {
      const area = document.createElement("textarea");
      area.value = text;
      area.setAttribute("readonly", "");
      area.style.position = "fixed";
      area.style.opacity = "0";
      document.body.appendChild(area);
      area.select();
      const copied = document.execCommand("copy");
      area.remove();
      return copied;
    } catch {
      return false;
    }
  }
}

export function CopyButton({ text, className = "copy-btn", label = "Copy" }: CopyButtonProps) {
  const [copied, setCopied] = useState(false);
  const timer = useRef<number | null>(null);

  useEffect(
    () => () => {
      if (timer.current !== null) window.clearTimeout(timer.current);
    },
    [],
  );

  const handleCopy = async () => {
    const copiedOk = await copyText(text);
    if (!copiedOk) return;
    setCopied(true);
    if (timer.current !== null) window.clearTimeout(timer.current);
    timer.current = window.setTimeout(() => setCopied(false), 1600);
  };

  return (
    <button
      type="button"
      className={className}
      onClick={handleCopy}
      aria-label={copied ? "Copied" : label}
    >
      <Icon name={copied ? "check" : "copy"} />
      <span>{copied ? "Copied" : label}</span>
    </button>
  );
}
