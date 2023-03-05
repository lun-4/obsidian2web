const treeMap = {};

function createTreeMap() {
  const tocLinks = document.getElementsByClassName("toc-link");
  for (const element of tocLinks) {
    const hrefUrl = new URL(element.href);
    treeMap[hrefUrl.pathname] = element;
  }
}

// Made with the following request to ChatGPT AS A SHITPOST:
// "Generate JavaScript code that, given a DOM element,
//  finds all parent elements that match a certain CSS selector."

function findMatchingParents(element, selector) {
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
  const element = treeMap[window.location.pathname];
  if (!element) return;
  let allParents = findMatchingParents(element, "details");

  for (let parentDetails of allParents) {
    parentDetails.open = true;
  }
  element.ariaCurrent = "page";
}

window.onload = function () {
  createTreeMap();
  openTreeFromPath();
};
