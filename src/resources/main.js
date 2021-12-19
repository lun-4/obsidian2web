window.onload = function () {
  var toggler = document.getElementsByClassName("caret");
  var i;

  for (i = 0; i < toggler.length; i++) {
    console.log("awooga", i);
    toggler[i].addEventListener("click", function () {
      console.log("sex");
      this.parentElement.querySelector(".nested").classList.toggle("active");
      this.classList.toggle("caret-down");
    });
  }
};
