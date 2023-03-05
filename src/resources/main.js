// @ts-check

/**
 * Made with the following request to ChatGPT AS A SHITPOST:
 * > "Generate JavaScript code that, given a DOM element,
 * > finds all parent elements that match a certain CSS selector."
 *
 * Type annotation added manually.
 *
 * @param {Element} element the element to begin looking from
 * @param {string} selector the selector to match parent elements against
 * @returns {Element[]}
 */
function findMatchingParents(element, selector) {
  /** @type {Element[]} */
  const matchingParents = [];
  let parent = element.parentElement;

  while (parent !== null) {
    if (parent.matches(selector)) {
      matchingParents.push(parent);
    }
    parent = parent.parentElement;
  }

  return matchingParents;
}

// Based on document.location, open the necessary tree buttons
function openTreeFromPath() {
  const element = document.querySelector("nav a[aria-current=page]");
  if (!element) return;
  let allParents = /** @type {HTMLDetailsElement[]} */ (
    findMatchingParents(element, "details")
  );

  for (let parentDetails of allParents) {
    parentDetails.open = true;
  }
}

window.onload = function () {
  openTreeFromPath();
};
