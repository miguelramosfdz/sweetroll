/*! Sweetroll by https://unrelenting.technology */
/* global localforage */

localforage.getItem('cached-pages').then(pages => {
	const list = document.getElementById('cached-list')
	for (const page of pages) {
		list.innerHTML += '<li><a href="' + page + '">' + page + '</a></li>'
	}
})
