//
//  ContactsViewController.swift
//  LoCo
//
//  Created by Drew McCormack on 17/01/2019.
//  Copyright © 2019 The Mental Faculty B.V. All rights reserved.
//

import UIKit

class ContactsViewController: UITableViewController {
    
    var contactBook: ContactBook!

    override func viewDidLoad() {
        super.viewDidLoad()
        
        navigationItem.leftBarButtonItem = editButtonItem

        let addButton = UIBarButtonItem(barButtonSystemItem: .add, target: self, action: #selector(addContact(_:)))
        navigationItem.rightBarButtonItem = addButton
    }

    override func viewWillAppear(_ animated: Bool) {
        clearsSelectionOnViewWillAppear = splitViewController!.isCollapsed
        tableView.reloadData()
        super.viewWillAppear(animated)
    }

    @objc func addContact(_ sender: Any) {
        let contact = Contact()
        try! contactBook.add(contact)
        let indexPath = IndexPath(row: contactBook.contacts.count-1, section: 0)
        tableView.insertRows(at: [indexPath], with: .automatic)
        view.isUserInteractionEnabled = false
        DispatchQueue.main.asyncAfter(deadline: .now()+0.3) {
            self.tableView.selectRow(at: indexPath, animated: true, scrollPosition: .none)
            DispatchQueue.main.asyncAfter(deadline: .now()+0.2) {
                self.performSegue(withIdentifier: "showContact", sender: self)
                self.view.isUserInteractionEnabled = true
            }
        }
    }

    override func prepare(for segue: UIStoryboardSegue, sender: Any?) {
        if segue.identifier == "showContact" {
            if let indexPath = tableView.indexPathForSelectedRow {
                let navController = segue.destination as! UINavigationController
                let contactViewController = navController.topViewController as! ContactViewController
                contactViewController.showContact(at: indexPath.row, in: contactBook)
                contactViewController.navigationItem.leftBarButtonItem = splitViewController?.displayModeButtonItem
                contactViewController.navigationItem.leftItemsSupplementBackButton = true
            }
        }
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        return 1
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return contactBook.contacts.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath)
        let contact = contactBook.contacts[indexPath.row].value
        let name = contact.person?.fullName ?? "Unnamed Contact"
        cell.textLabel!.text = "\(name)"
        return cell
    }

    override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        return true
    }

    override func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        if editingStyle == .delete {
            let contact = contactBook.contacts[indexPath.row].value
            try! contactBook.delete(contact)
            tableView.deleteRows(at: [indexPath], with: .fade)
        }
    }


}

