function getTarget(target: string | HTMLElement): HTMLElement | null {
  if (typeof target === 'string') {
    return document.getElementById(target);
  }

  return target;
}

export async function onMount(
  target: string | HTMLElement,
): Promise<HTMLElement> {
  return new Promise((resolve) => {
    let observer: MutationObserver | null = null;

    const resolveIfMountedAndVisible = () => {
      const mountedTarget = getTarget(target);

      if (
        mountedTarget &&
        mountedTarget.isConnected &&
        mountedTarget.offsetParent !== null
      ) {
        observer?.disconnect();
        resolve(mountedTarget);
        return true;
      }

      return false;
    };

    if (resolveIfMountedAndVisible()) {
      return;
    }

    observer = new MutationObserver(() => {
      resolveIfMountedAndVisible();
    });

    observer.observe(document.body, {
      childList: true,
      subtree: true,
      attributes: true,
      attributeFilter: ['class', 'style', 'hidden'],
    });
  });
}
